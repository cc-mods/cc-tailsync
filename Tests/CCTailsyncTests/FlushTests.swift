import XCTest
@testable import CCTailsync

/// Tests the GitHub-hub client's new flush helpers — the parts that are deterministic without a
/// network: the Contents-API PUT body builder, the PUT-response sha parser, and the `flush`
/// fast-paths (confirm-without-round-trip when already in sync, and the dormant no-op when
/// unconfigured). The actual network PUT and the background `URLSession` enqueue are intentionally
/// NOT exercised here (they require a live hub / would spin up a process-wide background session).
final class FlushTests: XCTestCase {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-flush-\(UUID().uuidString)-\(name)")
    }

    // MARK: putBody

    func testPutBodyIncludesBase64ContentAndMessage() {
        let content = Data("cc.save bytes".utf8)
        let body = GitHubSaveSyncClient.putBody(content: content, priorSha: nil)
        XCTAssertEqual(body["content"] as? String, content.base64EncodedString())
        XCTAssertTrue((body["message"] as? String)?.contains("sync: cc.save") == true)
        XCTAssertNotNil(body["committer"])
    }

    func testPutBodyIncludesShaOnlyWhenUpdating() {
        let content = Data("x".utf8)
        XCTAssertNil(GitHubSaveSyncClient.putBody(content: content, priorSha: nil)["sha"],
                     "create must omit sha")
        XCTAssertEqual(GitHubSaveSyncClient.putBody(content: content, priorSha: "abc123")["sha"] as? String,
                       "abc123", "update must carry the optimistic-lock sha")
    }

    // MARK: parsePutSha

    func testParsePutShaReadsContentSha() {
        let json = Data(#"{"content":{"sha":"deadbeef"},"commit":{}}"#.utf8)
        XCTAssertEqual(GitHubSaveSyncClient.parsePutSha(json), "deadbeef")
    }

    func testParsePutShaNilOnGarbage() {
        XCTAssertNil(GitHubSaveSyncClient.parsePutSha(nil))
        XCTAssertNil(GitHubSaveSyncClient.parsePutSha(Data("not json".utf8)))
        XCTAssertNil(GitHubSaveSyncClient.parsePutSha(Data(#"{"content":{}}"#.utf8)))
    }

    // MARK: flush fast-paths (no network)

    /// Configured + a local save whose content sha already equals `lastSyncedSha` → `flush` confirms
    /// `true` via the fast path, with no network round-trip (so a fake token is fine).
    func testFlushConfirmsImmediatelyWhenAlreadySynced() {
        let saveURL = tempURL("cc.save")
        let configURL = tempURL("cfg.json")
        let stateURL = tempURL("state.json")
        let saveBytes = Data("a synced save".utf8)
        try! saveBytes.write(to: saveURL)
        try! Data(#"{"repo":"o/r","path":"cc.save","token":"fake"}"#.utf8).write(to: configURL)
        let sha = GitHubSaveSyncClient.gitBlobSha(saveBytes)
        try! Data("{\"lastSyncedSha\":\"\(sha)\"}".utf8).write(to: stateURL)
        defer { for u in [saveURL, configURL, stateURL] { try? FileManager.default.removeItem(at: u) } }

        let client = GitHubSaveSyncClient(saveFileURL: saveURL, configURL: configURL, stateURL: stateURL)
        let done = expectation(description: "flush confirmed")
        var result: Bool?
        client.flush(timeout: 5) { ok in result = ok; done.fulfill() }
        wait(for: [done], timeout: 2)   // must resolve well under the 5s timeout → proves no round-trip
        XCTAssertEqual(result, true)
    }

    /// Unconfigured (no config file) → `flush` is a dormant no-op that confirms `true` at once, so the
    /// Close/Restart buttons never block on a build with sync turned off.
    func testFlushNoOpWhenUnconfigured() {
        let saveURL = tempURL("cc.save")
        try! Data("save".utf8).write(to: saveURL)
        defer { try? FileManager.default.removeItem(at: saveURL) }
        let client = GitHubSaveSyncClient(saveFileURL: saveURL,
                                          configURL: tempURL("missing-cfg.json"),
                                          stateURL: tempURL("missing-state.json"))
        let done = expectation(description: "flush no-op")
        var result: Bool?
        client.flush(timeout: 5) { ok in result = ok; done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(result, true)
    }

    /// `flushInBackground` is dormant when unconfigured: it returns without enqueuing anything (no
    /// background upload temp file is produced, and no background session is created).
    func testFlushInBackgroundDormantWhenUnconfigured() {
        let saveURL = tempURL("cc.save")
        try! Data("save".utf8).write(to: saveURL)
        defer { try? FileManager.default.removeItem(at: saveURL) }
        let client = GitHubSaveSyncClient(saveFileURL: saveURL,
                                          configURL: tempURL("missing-cfg.json"),
                                          stateURL: tempURL("missing-state.json"))
        client.flushInBackground()   // must not throw, hang, or enqueue
        let tmp = FileManager.default.temporaryDirectory
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("ccsave-bg-") },
                       "dormant flushInBackground must not write a background-upload body file")
    }
}
