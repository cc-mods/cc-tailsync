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

    /// Two-way sync with the server, resolving by modification time with a content-hash
    /// short-circuit. Calls back `true` only if the local save file was updated from the server
    /// (the caller should then load it).
    ///
    /// Resolution: identical hashes → nothing to do; otherwise the side with the newer mtime wins —
    /// a newer **remote** is pulled, a newer **local** is pushed. This avoids clobbering progress
    /// made offline on either side.
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
            let remoteMtime = (obj["mtime"] as? Int) ?? 0

            // Nothing on the server → upload whatever we have locally.
            if !remoteExists {
                if let value = local?.value { self.push(value) }
                completion(false); return
            }
            // Nothing locally → take the server's save.
            guard let local = local else {
                self.downloadSave(config: config, expectedSha: remoteSha, completion: completion)
                return
            }
            // In sync already.
            if local.sha == remoteSha { self.lastSyncedSha = remoteSha; completion(false); return }
            // Newer side wins.
            if remoteMtime > local.mtime {
                self.downloadSave(config: config, expectedSha: remoteSha, completion: completion)
            } else {
                self.push(local.value)
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
