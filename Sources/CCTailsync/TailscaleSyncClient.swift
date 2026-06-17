import Foundation
import CryptoKit

/// Optional wireless save sync for CrossCode against a **save-server** (e.g. a PC on your Tailscale
/// network — see `servers/save-server.py`). This is the iOS-side client of the **cc-tailsync**
/// suite.
///
/// It is consumed by the **cc-ios** app through cc-ios's `SaveSyncProvider` seam. cc-ios *owns* that
/// protocol; this type conforms to it **structurally** — it implements `isConfigured`,
/// `pullIfNewerBlocking(timeout:)` and `push(_:)` with matching signatures — so the conformance is a
/// one-line `extension TailscaleSyncClient: SaveSyncProvider {}` added in cc-ios at integration time
/// (`tools/integrate-ios.sh`). That keeps this package free of any cc-ios dependency.
///
/// Entirely **fail-safe**: with no config file, or an unreachable server, every call is a silent
/// no-op — it can never block boot or break the game.
///
/// Construction is decoupled from any host type: pass the local save file URL (cc-ios passes its
/// `Documents/cc.save`) and, optionally, the config URL (defaults to `Documents/cc-sync.json`):
///
///     { "url": "http://100.x.y.z:8765", "token": "optional-bearer" }
///
/// The server mirrors the desktop `cc.save`, which Steam Cloud distributes across your PCs — so this
/// bridges iOS into the same save, wirelessly.
public final class TailscaleSyncClient {

    public struct Config {
        public let url: URL
        public let token: String?
    }

    private let saveFileURL: URL
    private let configURL: URL
    private let session: URLSession
    private var lastSyncedSha: String?

    /// - Parameters:
    ///   - saveFileURL: the local canonical save file (cc-ios passes `Documents/cc.save`). Pulled
    ///     saves are written here; local saves are read from here for the newest-wins comparison.
    ///   - configURL: the sync config JSON. Defaults to `Documents/cc-sync.json`.
    public init(saveFileURL: URL, configURL: URL? = nil) {
        self.saveFileURL = saveFileURL
        self.configURL = configURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc-sync.json")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: cfg)
    }

    /// Reads the config JSON, or `nil` if absent/invalid (→ sync disabled).
    public func loadConfig() -> Config? {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = obj["url"] as? String,
              let endpoint = URL(string: urlString) else {
            return nil
        }
        return Config(url: endpoint, token: obj["token"] as? String)
    }

    /// Whether a usable sync endpoint is configured.
    public var isConfigured: Bool { loadConfig() != nil }

    /// Blocking variant for use at launch (before the save is injected): pulls a newer remote save
    /// into the local save file, waiting up to `timeout` seconds. Returns whether the local file was
    /// updated. If sync isn't configured it returns instantly; if the server is slow/unreachable it
    /// gives up after the timeout (the pull may still finish in the background for the next launch).
    public func pullIfNewerBlocking(timeout: TimeInterval) -> Bool {
        guard isConfigured else { return false }
        let sem = DispatchSemaphore(value: 0)
        var changed = false
        pullIfNewer { c in changed = c; sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        return changed
    }

    private func authorized(_ request: inout URLRequest, _ config: Config) {
        if let token = config.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// The launch-sync policy. **Phone-authoritative**: the device's own save is the source of truth
    /// and is NEVER overwritten from the server on launch. We only adopt the server's save when there
    /// is no local save at all (a fresh install or a post-restore device) — the first-run seed.
    /// Otherwise the local save wins and is pushed up if the server differs.
    ///
    /// This deliberately drops the old "newer mtime wins" comparison: `remoteMtime` is the **server
    /// machine's** clock and `localMtime` is the **phone's** clock, so any skew could make an older
    /// server save look "newer" and silently clobber fresh on-device progress at launch. Comparing two
    /// devices' wall clocks to decide a destructive overwrite is never safe. (A future, safer two-way
    /// design uses a content SHA + an explicit "newer save detected — load? Y/N" prompt; see the
    /// GitHub-hub client.)
    enum PullAction: Equatable {
        case seedFromServer(sha: String)  // no local save → take the server's
        case pushLocal                    // local save wins → upload it (server missing or differs)
        case inSync                       // local == server → nothing to do
        case noRemoteNoLocal              // neither side has a save → nothing to do
    }

    /// Pure resolver for the phone-authoritative policy (no I/O — unit-tested directly).
    static func resolvePull(localSha: String?, remoteExists: Bool, remoteSha: String) -> PullAction {
        guard let localSha = localSha else {
            return remoteExists ? .seedFromServer(sha: remoteSha) : .noRemoteNoLocal
        }
        if remoteExists && remoteSha == localSha { return .inSync }
        return .pushLocal
    }

    /// Launch sync against the server, applying the phone-authoritative policy above. Calls back
    /// `true` only if the local save file was seeded from the server (the caller should then load it).
    public func pullIfNewer(completion: @escaping (Bool) -> Void) {
        guard let config = loadConfig() else { completion(false); return }
        var request = URLRequest(url: config.url.appendingPathComponent("status"))
        authorized(&request, config)

        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { completion(false); return }
            let local = self.localSaveInfo()

            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false); return
            }
            let remoteExists = (obj["exists"] as? Bool) == true
            let remoteSha = obj["sha256"] as? String ?? ""

            switch Self.resolvePull(localSha: local?.sha, remoteExists: remoteExists, remoteSha: remoteSha) {
            case .seedFromServer(let sha):
                // No local save (fresh install / restore): adopt the server's. This is the ONLY path
                // that writes the local file from the server, and only when there's nothing to lose.
                self.downloadSave(config: config, expectedSha: sha, completion: completion)
            case .pushLocal:
                // Local save is authoritative and differs from (or is missing on) the server → upload.
                if let value = local?.value { self.push(value) }
                completion(false)
            case .inSync:
                self.lastSyncedSha = remoteSha
                completion(false)
            case .noRemoteNoLocal:
                completion(false)
            }
        }.resume()
    }

    private func downloadSave(config: Config, expectedSha: String,
                             completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: config.url.appendingPathComponent("cc.save"))
        authorized(&request, config)
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self,
                  let data = data, !data.isEmpty,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                completion(false); return
            }
            do {
                try data.write(to: self.saveFileURL, options: .atomic)
                self.lastSyncedSha = expectedSha
                NSLog("[cc-tailsync] pulled %d bytes from server", data.count)
                completion(true)
            } catch {
                NSLog("[cc-tailsync] pull write failed: %@", error.localizedDescription)
                completion(false)
            }
        }.resume()
    }

    /// Uploads the given save bytes to the server, skipping if unchanged since the last sync.
    public func push(_ value: String) {
        guard let config = loadConfig() else { return }
        let data = Data(value.utf8)
        let sha = Self.sha256(data)
        guard sha != lastSyncedSha else { return }   // dedupe echoes

        var request = URLRequest(url: config.url.appendingPathComponent("cc.save"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        authorized(&request, config)
        request.httpBody = data

        session.dataTask(with: request) { [weak self] _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                self?.lastSyncedSha = sha
                NSLog("[cc-tailsync] pushed %d bytes to server", data.count)
            }
        }.resume()
    }

    // MARK: - Local save info

    private struct LocalInfo { let value: String; let sha: String; let mtime: Int }

    private func localSaveInfo() -> LocalInfo? {
        guard let data = try? Data(contentsOf: saveFileURL), !data.isEmpty,
              let value = String(data: data, encoding: .utf8) else { return nil }
        let mtime: Int
        if let attrs = try? FileManager.default.attributesOfItem(atPath: saveFileURL.path),
           let date = attrs[.modificationDate] as? Date {
            mtime = Int(date.timeIntervalSince1970)
        } else {
            mtime = 0
        }
        return LocalInfo(value: value, sha: Self.sha256(data), mtime: mtime)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
