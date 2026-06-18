import Foundation

/// Durable, out-of-process save upload for `GitHubSaveSyncClient.flushInBackground()`.
///
/// A normal `URLSession` task dies the instant the app is suspended or force-quit — exactly when we
/// most need the last save to reach the hub (you swipe CrossCode away, or iOS reclaims it while
/// backgrounded). A **background `URLSession`** instead hands the transfer to the system daemon
/// (`nsurlsessiond`), which runs it independently of the app's lifetime and briefly relaunches the
/// app to deliver the result. This is the only iOS-sanctioned way to guarantee an upload survives the
/// app going away — you cannot block termination, so you make the work outlive it.
///
/// Design notes:
///   • Background uploads must be **file-backed** (`uploadTask(with:fromFile:)`); we serialize the
///     Contents-API PUT body to a temp file and clean it up on completion.
///   • The session identifier is process-wide and must be **stable** — iOS reconnects pending tasks
///     to a session recreated with the same id at next launch (`reconnect()`), then drains their
///     results through this delegate.
///   • The session is built lazily, so merely *owning* an uploader never creates it; only the
///     background entry points do. That keeps multiple `GitHubSaveSyncClient` instances (e.g. in
///     unit tests) from fighting over the one allowed session for this identifier.
final class BackgroundSaveUploader: NSObject {

    /// Stable, process-wide identifier for the background session (bundle-id-prefixed by convention).
    static let sessionIdentifier = "com.example.ccios.savesync.bg"

    private let onSyncedSha: (String) -> Void
    private let lock = NSLock()
    private var responseBytes: [Int: Data] = [:]      // accumulated PUT response body, per task
    private var pendingSystemCompletion: (() -> Void)?

    init(onSyncedSha: @escaping (String) -> Void) {
        self.onSyncedSha = onSyncedSha
        super.init()
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false        // upload ASAP, don't wait for "optimal" conditions
        cfg.allowsCellularAccess = true
        #if os(iOS)
        cfg.sessionSendsLaunchEvents = true // let iOS relaunch us to deliver completion
        #endif
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// Touch the lazy session so the OS can reconnect tasks that completed while the app was away.
    func reconnect() { _ = session }

    /// Serialize the PUT body to a temp file and enqueue a durable background upload.
    func enqueue(config: GitHubSaveSyncClient.Config, content: Data, priorSha: String?) {
        let body = GitHubSaveSyncClient.putBody(content: content, priorSha: priorSha)
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccsave-bg-\(UUID().uuidString).json")
        do { try bodyData.write(to: tmp, options: .atomic) } catch { return }

        var request = GitHubSaveSyncClient.authorizedRequest(config)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let task = session.uploadTask(with: request, fromFile: tmp)
        task.taskDescription = tmp.path     // remember the temp file so we can delete it on completion
        task.resume()
    }

    /// Store the system completion handler (run once this session's events drain) and ensure the
    /// session is alive to receive them. Foreign identifiers complete immediately.
    func handleEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { completion(); return }
        lock.lock(); pendingSystemCompletion = completion; lock.unlock()
        _ = session
    }
}

extension BackgroundSaveUploader: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responseBytes[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock(); let bytes = responseBytes.removeValue(forKey: id); lock.unlock()

        if let path = task.taskDescription { try? FileManager.default.removeItem(atPath: path) }

        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil, status == 200 || status == 201,
           let sha = GitHubSaveSyncClient.parsePutSha(bytes) {
            onSyncedSha(sha)
        }
        // 409 (optimistic-lock conflict) or any error → drop; the next launch reconciles, and the
        // phone is authoritative, so a missed background push is never data loss (only deferred sync).
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let completion = pendingSystemCompletion; pendingSystemCompletion = nil; lock.unlock()
        DispatchQueue.main.async { completion?() }
    }
}
