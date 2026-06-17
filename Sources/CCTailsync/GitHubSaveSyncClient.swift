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
/// The device persists the blob SHA it last synced (`lastSyncedSha`); on a check we compare {local
/// content sha, remote sha, lastSynced} to decide:
///   - identical content                       → `.inSync`
///   - local changed, remote unchanged          → `.pushLocal`  (local strictly ahead — upload)
///   - remote moved (and differs from local)    → `.offerLoadRemote` (prompt "newer save — load? Y/N")
/// Writes use `PUT` with the prior blob SHA as an **optimistic lock** (409 on a concurrent change),
/// so no last-writer-wins races. The host (cc-ios) owns the actual Y/N prompt + applying a pulled
/// save; this type is logic + transport only (no UI), matching the suite's separation.
///
/// **Fail-safe & dormant by default.** With no config file (no repo/token) every call is a silent
/// no-op — so shipping this code costs nothing until you opt in by dropping a `cc-github.json` with a
/// fine-grained PAT (one repo, Contents read/write) into the app's Documents directory.
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

    /// - Parameters:
    ///   - saveFileURL: the local canonical save (cc-ios passes `Documents/cc.save`).
    ///   - configURL: the sync config JSON. Defaults to `Documents/cc-github.json`.
    ///   - stateURL: where the last-synced blob SHA is persisted. Defaults to `Documents/cc-github-state.json`.
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

    /// What a home-screen check should do, given local content SHA, the last-synced SHA, and the
    /// remote SHA (any of which may be absent). Pure — the decision core of the whole client.
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

    // MARK: - Remote check (GET) — decides, never auto-overwrites the local save

    /// The result of a home-screen check. `.offerLoadRemote` carries the downloaded remote bytes +
    /// its sha so the host can apply it iff the user says yes.
    public enum CheckResult {
        case inSync
        case pushed                                   // local was ahead and has been uploaded
        case seededHub                                // hub was empty; local uploaded as the baseline
        case offerLoadRemote(content: Data, remoteSha: String)
        case notConfigured
        case failed
    }

    /// Read the hub's current file metadata + content, compare by content SHA, and either upload a
    /// strictly-newer local save, report in-sync, or hand back the remote bytes for the host to offer
    /// via a "newer save detected — load? Y/N" prompt. NEVER writes the local save file itself.
    public func check(completion: @escaping (CheckResult) -> Void) {
        guard let config = loadConfig() else { completion(.notConfigured); return }
        let localData = try? Data(contentsOf: saveFileURL)
        let localSha = localData.map { Self.gitBlobSha($0) }

        var request = contentsRequest(config)
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { completion(.failed); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 404 → file not in the hub yet.
            var remoteSha: String?
            var remoteContent: Data?
            if status == 200, let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                remoteSha = obj["sha"] as? String
                if let b64 = obj["content"] as? String {
                    let cleaned = b64.replacingOccurrences(of: "\n", with: "")
                    remoteContent = Data(base64Encoded: cleaned)
                }
            } else if status != 404 {
                completion(.failed); return
            }

            switch Self.resolveCheck(localBlobSha: localSha,
                                     lastSyncedSha: self.loadLastSyncedSha(),
                                     remoteBlobSha: remoteSha) {
            case .inSync:
                if let s = remoteSha { self.saveLastSyncedSha(s) }
                completion(.inSync)
            case .pushLocal:
                guard let value = localData else { completion(.failed); return }
                self.put(config: config, content: value, priorSha: remoteSha) { ok in
                    completion(ok ? .pushed : .failed)
                }
            case .firstPush:
                guard let value = localData else { completion(.failed); return }
                self.put(config: config, content: value, priorSha: nil) { ok in
                    completion(ok ? .seededHub : .failed)
                }
            case .offerLoadRemote:
                if let content = remoteContent, let s = remoteSha {
                    completion(.offerLoadRemote(content: content, remoteSha: s))
                } else { completion(.failed) }
            case .nothing:
                completion(.inSync)
            }
        }.resume()
    }

    /// Adopt a remote save the user accepted from `offerLoadRemote`: write it to the local file and
    /// record its sha as the new sync point. (The host then reloads the game from the file.)
    public func applyPulled(content: Data, remoteSha: String) -> Bool {
        do {
            try content.write(to: saveFileURL, options: .atomic)
            saveLastSyncedSha(remoteSha)
            return true
        } catch {
            NSLog("[cc-github] applyPulled write failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Upload the given save bytes to the hub (used after an in-game save). Reads the current remote
    /// sha first to satisfy the optimistic-lock precondition; on a 409 the next home-screen check will
    /// surface the divergence as an offer-to-load.
    public func push(_ value: String) {
        guard let config = loadConfig() else { return }
        let data = Data(value.utf8)
        var request = contentsRequest(config)
        session.dataTask(with: request) { [weak self] respData, response, _ in
            guard let self = self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var priorSha: String?
            if status == 200, let respData = respData,
               let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] {
                priorSha = obj["sha"] as? String
                if priorSha == Self.gitBlobSha(data) { return } // already current
            }
            self.put(config: config, content: data, priorSha: priorSha) { _ in }
        }.resume()
    }

    // MARK: - HTTP plumbing

    private func contentsURL(_ config: Config) -> URL {
        URL(string: "https://api.github.com/repos/\(config.repo)/contents/\(config.path)")!
    }

    private func contentsRequest(_ config: Config) -> URLRequest {
        var request = URLRequest(url: contentsURL(config))
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func put(config: Config, content: Data, priorSha: String?,
                     completion: @escaping (Bool) -> Void) {
        var body: [String: Any] = [
            "message": "sync: cc.save \(ISO8601DateFormatter().string(from: Date()))",
            "content": content.base64EncodedString(),
            "committer": ["name": "cc-saves sync", "email": "ccsync@users.noreply.github.com"],
        ]
        if let priorSha = priorSha { body["sha"] = priorSha } // omit on create (firstPush)

        var request = contentsRequest(config)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (status == 200 || status == 201), let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let contentObj = obj["content"] as? [String: Any],
               let newSha = contentObj["sha"] as? String {
                self?.saveLastSyncedSha(newSha)
                completion(true)
            } else {
                // 409 = optimistic-lock conflict (remote moved). The next check() surfaces it as an
                // offer-to-load; we don't blindly overwrite.
                completion(false)
            }
        }.resume()
    }
}
