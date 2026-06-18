import Foundation
import CryptoKit

/// GitHub-hub save sync for CrossCode: uses a private GitHub repo (the **cc-saves** hub) as the
/// always-online source of truth for `cc.save`, via the GitHub **Contents API** over plain HTTPS
/// (no `git` binary). It is the next-generation alternative to `TailscaleSyncClient` — it removes the
/// always-on-PC requirement and the cross-device mtime footgun, and gives free versioned history
/// (every push is a commit / recoverable snapshot).
///
/// **Conflict model — content identity, never wall-clock time.** GitHub's Contents API returns a git
/// **blob SHA** for the file (SHA-1 of `"blob <len>\0" + bytes`, exactly what `git hash-object`
/// computes). We compute the same locally, so "did anything change?" is a pure content comparison.
/// The device persists the blob SHA it last synced (`lastSyncedSha`); see `resolveCheck` for the
/// decision table.
///
/// **Two safe entry points for cc-ios:**
///  - `pullIfNewerBlocking(timeout:)` at launch — phone-authoritative & non-interactive: seeds the
///    local save only when there is NO local save (fresh install / restore), pushes when the local is
///    strictly ahead, and otherwise does nothing. It **never** overwrites an existing local save, and
///    it never prompts.
///  - `checkForConsentPull(completion:)` after boot — if a local save exists AND the hub holds a
///    different, advanced save, it hands the remote bytes back so the host can show a
///    **"newer save detected — load? Y/N"** prompt. Applying is the host's call (`applyPulledConsent`).
///
/// **Fail-safe & dormant by default.** With no config file (no repo/token) every call is a silent
/// no-op — so shipping this costs nothing until a `Documents/cc-github.json`
/// (`{ "repo", "path", "token" }`, a fine-grained PAT with Contents:R/W on the one repo) is present.
public final class GitHubSaveSyncClient {

    public struct Config {
        public let repo: String      // "owner/name", e.g. "cc-mods/cc-saves"
        public let path: String      // file path in the repo, e.g. "cc.save"
        public let token: String     // fine-grained PAT (Contents: read/write on this repo only)
    }

    private let saveFileURL: URL
    private let configURL: URL
    private let stateURL: URL
    private let session: URLSession

    /// The remote sha of the offer currently awaiting the user's decision (set by
    /// `checkForConsentPull`, consumed by `applyPulledConsent`).
    private var pendingRemoteSha: String?

    /// Durable background uploader (a background `URLSession`). Lazily built so merely constructing a
    /// client never spins up a background session — only the explicit background paths
    /// (`flushInBackground`, `reconnectBackgroundSession`, `handleBackgroundEvents`) do, which keeps
    /// the unit tests (and any extra client instances) free of a process-wide session-identifier clash.
    private lazy var backgroundUploader = BackgroundSaveUploader(
        onSyncedSha: { [weak self] sha in self?.saveLastSyncedSha(sha) }
    )

    public init(saveFileURL: URL, configURL: URL? = nil, stateURL: URL? = nil) {
        self.saveFileURL = saveFileURL
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.configURL = configURL ?? docs.appendingPathComponent("cc-github.json")
        self.stateURL = stateURL ?? docs.appendingPathComponent("cc-github-state.json")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 25
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Config / state

    public func loadConfig() -> Config? {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repo = obj["repo"] as? String, !repo.isEmpty,
              let token = obj["token"] as? String, !token.isEmpty else {
            return nil
        }
        let path = (obj["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "cc.save"
        return Config(repo: repo, path: path, token: token)
    }

    /// Whether a usable GitHub hub is configured (repo + token present).
    public var isConfigured: Bool { loadConfig() != nil }

    public func loadLastSyncedSha() -> String? {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["lastSyncedSha"] as? String
    }

    public func saveLastSyncedSha(_ sha: String) {
        let data = try? JSONSerialization.data(withJSONObject: ["lastSyncedSha": sha])
        try? data?.write(to: stateURL, options: .atomic)
    }

    // MARK: - Pure helpers (unit-tested; no I/O)

    /// The git blob SHA of `data` — SHA-1 of `"blob <len>\0" + data`, identical to `git hash-object`
    /// and to the `sha` the GitHub Contents API returns. This is how we compare content without ever
    /// touching a wall clock.
    public static func gitBlobSha(_ data: Data) -> String {
        var input = Data("blob \(data.count)\u{0}".utf8)
        input.append(data)
        return Insecure.SHA1.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    /// What a check should conclude, given local content SHA, the last-synced SHA, and the remote SHA
    /// (any of which may be absent). Pure — the decision core, shared by the launch and consent paths
    /// and mirrored by the Python PC bridge.
    public enum SyncAction: Equatable {
        case inSync               // remote content == local content → nothing to do
        case pushLocal            // local strictly ahead (remote unchanged since last sync) → upload
        case offerLoadRemote      // remote moved/differs → host should prompt "newer save — load? Y/N"
        case firstPush            // remote absent, local present → seed the hub
        case nothing              // neither side has a save
    }

    public static func resolveCheck(localBlobSha: String?,
                                    lastSyncedSha: String?,
                                    remoteBlobSha: String?) -> SyncAction {
        switch (localBlobSha, remoteBlobSha) {
        case (nil, nil):  return .nothing
        case (nil, _?):   return .offerLoadRemote   // fresh device, hub has a save → offer to load it
        case (_?, nil):   return .firstPush          // local save, empty hub → seed it
        case let (local?, remote?):
            if local == remote { return .inSync }
            if remote == lastSyncedSha { return .pushLocal } // remote hasn't moved → local is ahead
            return .offerLoadRemote                           // remote advanced → ask before overwriting
        }
    }

    // MARK: - Launch sync (blocking, non-interactive, phone-authoritative)

    /// Blocking launch sync. Seeds the local save ONLY when there is no local save (fresh install /
    /// restore); pushes when the local save is strictly ahead or the hub is empty; otherwise does
    /// nothing. NEVER overwrites an existing local save and NEVER prompts. Returns whether the local
    /// file was written (seeded) — the caller should then re-read it for injection.
    public func pullIfNewerBlocking(timeout: TimeInterval) -> Bool {
        guard isConfigured else { return false }
        let sem = DispatchSemaphore(value: 0)
        var seeded = false
        fetchRemote { [weak self] remoteSha, remoteContent in
            defer { sem.signal() }
            guard let self = self, let config = self.loadConfig() else { return }
            let localData = try? Data(contentsOf: self.saveFileURL)
            let localSha = localData.map { Self.gitBlobSha($0) }

            // No local save → safe to adopt the hub's (nothing to lose). This is the only path that
            // writes the local file at launch, and only when there's no on-device progress to protect.
            if localSha == nil {
                if let content = remoteContent, let sha = remoteSha {
                    do {
                        try content.write(to: self.saveFileURL, options: .atomic)
                        self.saveLastSyncedSha(sha)
                        seeded = true
                    } catch {
                        NSLog("[cc-github] seed write failed: %@", error.localizedDescription)
                    }
                }
                return
            }

            switch Self.resolveCheck(localBlobSha: localSha,
                                     lastSyncedSha: self.loadLastSyncedSha(),
                                     remoteBlobSha: remoteSha) {
            case .inSync:
                if let sha = remoteSha { self.saveLastSyncedSha(sha) }
            case .pushLocal, .firstPush:
                if let value = localData { self.putBlocking(config: config, content: value, priorSha: remoteSha) }
            case .offerLoadRemote:
                break   // a real divergence — left for the consent prompt, never auto-applied
            case .nothing:
                break
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return seeded
    }

    // MARK: - Consent pull (interactive; host shows the Y/N prompt)

    /// Non-destructive check for the home-screen prompt. Calls back with the hub's bytes IFF a local
    /// save exists AND the hub holds a different, advanced save (the `.offerLoadRemote` case); else nil.
    /// Never writes the local save — the host decides via `applyPulledConsent` after the user accepts.
    public func checkForConsentPull(completion: @escaping (Data?) -> Void) {
        guard isConfigured else { completion(nil); return }
        fetchRemote { [weak self] remoteSha, remoteContent in
            guard let self = self else { completion(nil); return }
            let localData = try? Data(contentsOf: self.saveFileURL)
            let localSha = localData.map { Self.gitBlobSha($0) }
            guard localSha != nil else { completion(nil); return } // fresh device → launch path seeds

            switch Self.resolveCheck(localBlobSha: localSha,
                                     lastSyncedSha: self.loadLastSyncedSha(),
                                     remoteBlobSha: remoteSha) {
            case .offerLoadRemote:
                if let content = remoteContent, let sha = remoteSha {
                    self.pendingRemoteSha = sha
                    completion(content)
                } else { completion(nil) }
            default:
                completion(nil)
            }
        }
    }

    /// Apply bytes the user accepted from a consent prompt: write them to the local save file and
    /// record the sync point. Returns success. (The host then reloads the game from the new save.)
    public func applyPulledConsent(_ data: Data) -> Bool {
        do {
            try data.write(to: saveFileURL, options: .atomic)
            saveLastSyncedSha(pendingRemoteSha ?? Self.gitBlobSha(data))
            pendingRemoteSha = nil
            return true
        } catch {
            NSLog("[cc-github] applyPulledConsent write failed: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Push (on in-game save)

    /// Upload the given save bytes to the hub. Reads the current remote sha first for the optimistic
    /// lock; on a 409 the next consent check surfaces the divergence as an offer-to-load.
    public func push(_ value: String) {
        guard let config = loadConfig() else { return }
        let data = Data(value.utf8)
        fetchRemote { [weak self] remoteSha, _ in
            guard let self = self else { return }
            if let remoteSha = remoteSha, remoteSha == Self.gitBlobSha(data) {
                self.saveLastSyncedSha(remoteSha); return            // already current
            }
            self.put(config: config, content: data, priorSha: remoteSha) { _ in }
        }
    }

    // MARK: - Confirmed flush (deliberate exit: Close / Restart buttons)

    /// Push the current local save and confirm the hub holds it, then call back on the main queue.
    /// Used by the host's "Close Game" / "Restart Game" buttons, which it fully controls — so a brief,
    /// bounded wait on the network before exiting/reloading is legitimate (the one place we block).
    ///
    /// Guarantees: the completion runs **exactly once** and **no later than `timeout`** (a dead
    /// network must never trap the user in the app), and `true` is returned immediately when there is
    /// nothing to do (unconfigured, no local save, or already in sync). `false` means "couldn't
    /// confirm in time" — the caller proceeds anyway; the save is already safe on disk and the next
    /// launch reconciles.
    public func flush(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let latch = OnceFlag()
        func finish(_ ok: Bool) { latch.run { DispatchQueue.main.async { completion(ok) } } }

        guard isConfigured, let config = loadConfig(),
              let localData = try? Data(contentsOf: saveFileURL), !localData.isEmpty else {
            finish(true); return   // nothing to sync → never block the exit
        }
        // Hard upper bound, independent of the network stack's own timeouts.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }

        let localSha = Self.gitBlobSha(localData)
        // Fast path: this exact save was already confirmed on the hub (we just pushed it, or nothing
        // changed since the last successful sync) → no round-trip, so exit/reload stays instant.
        if localSha == loadLastSyncedSha() { finish(true); return }
        fetchRemote { [weak self] remoteSha, _ in
            guard let self = self else { finish(false); return }
            if remoteSha == localSha {                       // hub already holds this exact save
                self.saveLastSyncedSha(localSha); finish(true); return
            }
            self.put(config: config, content: localData, priorSha: remoteSha) { ok in finish(ok) }
        }
    }

    // MARK: - Durable background flush (app suspension / termination)

    /// Hand the latest save to the OS via a background `URLSession` so the upload completes even if the
    /// app is suspended or force-quit. Returns immediately. Uses `lastSyncedSha` as the optimistic
    /// lock (no in-process GET needed → nothing to cut short on suspension); if a PC advanced the hub
    /// in the meantime the PUT 409s and is dropped, and the next launch reconciles (phone-authoritative).
    /// No-op when unconfigured, when there's no local save, or when nothing changed since the last sync.
    public func flushInBackground() {
        guard isConfigured, let config = loadConfig(),
              let localData = try? Data(contentsOf: saveFileURL), !localData.isEmpty else { return }
        let localSha = Self.gitBlobSha(localData)
        if localSha == loadLastSyncedSha() { return }   // unchanged since the last successful sync
        backgroundUploader.enqueue(config: config, content: localData, priorSha: loadLastSyncedSha())
    }

    /// Recreate the background session at launch so iOS can reconnect any tasks that finished while the
    /// app was away (and deliver their completion via `handleBackgroundEvents`). Call once on startup.
    public func reconnectBackgroundSession() { backgroundUploader.reconnect() }

    /// Forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to the uploader.
    public func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        backgroundUploader.handleEvents(identifier: identifier, completion: completion)
    }

    // MARK: - HTTP plumbing

    static func contentsURL(_ config: Config) -> URL {
        URL(string: "https://api.github.com/repos/\(config.repo)/contents/\(config.path)")!
    }

    /// Base authorized request (GET-shaped) for the Contents API. PUT callers add the method + body.
    static func authorizedRequest(_ config: Config) -> URLRequest {
        var request = URLRequest(url: contentsURL(config))
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// The JSON body for a Contents-API PUT (create or update). Omit `priorSha` to create.
    /// Shared by the in-process push and the durable background uploader so both speak identically.
    static func putBody(content: Data, priorSha: String?) -> [String: Any] {
        var body: [String: Any] = [
            "message": "sync: cc.save \(ISO8601DateFormatter().string(from: Date()))",
            "content": content.base64EncodedString(),
            "committer": ["name": "cc-saves sync", "email": "ccsync@users.noreply.github.com"],
        ]
        if let priorSha = priorSha { body["sha"] = priorSha } // omit on create (firstPush)
        return body
    }

    /// Extract the new blob sha from a Contents-API PUT response body (`content.sha`).
    static func parsePutSha(_ data: Data?) -> String? {
        guard let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentObj = obj["content"] as? [String: Any] else { return nil }
        return contentObj["sha"] as? String
    }

    /// GET the file; call back `(remoteBlobSha?, remoteContent?)` — both nil on a 404 or error.
    private func fetchRemote(completion: @escaping (String?, Data?) -> Void) {
        guard let config = loadConfig() else { completion(nil, nil); return }
        session.dataTask(with: Self.authorizedRequest(config)) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, nil); return
            }
            let sha = obj["sha"] as? String
            var content: Data?
            if let b64 = obj["content"] as? String {
                content = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: ""))
            }
            completion(sha, content)
        }.resume()
    }

    private func put(config: Config, content: Data, priorSha: String?,
                     completion: @escaping (Bool) -> Void) {
        var request = Self.authorizedRequest(config)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.putBody(content: content, priorSha: priorSha))

        session.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (status == 200 || status == 201), let newSha = Self.parsePutSha(data) {
                self?.saveLastSyncedSha(newSha)
                completion(true)
            } else {
                completion(false) // 409 = optimistic-lock conflict; surfaced later via a consent check
            }
        }.resume()
    }

    /// Blocking PUT used by the launch path (already inside a semaphore-bounded callback).
    private func putBlocking(config: Config, content: Data, priorSha: String?) {
        let sem = DispatchSemaphore(value: 0)
        put(config: config, content: content, priorSha: priorSha) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 6)
    }
}

/// A tiny thread-safe latch: runs the first `run` block and ignores the rest. Lets `flush` resolve via
/// whichever fires first — the network callback or the timeout — without a double completion.
final class OnceFlag {
    private var fired = false
    private let lock = NSLock()
    func run(_ block: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { block() }
    }
}
