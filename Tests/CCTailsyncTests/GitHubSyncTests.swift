import XCTest
@testable import CCTailsync

/// Tests the GitHub-hub sync client's pure core: the git-blob-SHA hasher (must match `git hash-object`
/// and the GitHub Contents API `sha`) and the content-identity conflict resolver (which decides
/// in-sync / push / offer-to-load WITHOUT ever comparing wall-clock times).
final class GitHubSyncTests: XCTestCase {

    typealias Action = GitHubSaveSyncClient.SyncAction

    // gitBlobSha must equal `git hash-object` for the same bytes (reference values computed with git).
    func testGitBlobShaMatchesGitHashObject() {
        XCTAssertEqual(GitHubSaveSyncClient.gitBlobSha(Data("".utf8)),
                       "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        XCTAssertEqual(GitHubSaveSyncClient.gitBlobSha(Data("hello".utf8)),
                       "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
        XCTAssertEqual(GitHubSaveSyncClient.gitBlobSha(Data("cc.save-test-payload".utf8)),
                       "176bd1a5675cd82c12cf1acfbdb9a92b36cd0260")
    }

    // Identical content on both sides → nothing to do.
    func testIdenticalContentIsInSync() {
        XCTAssertEqual(
            GitHubSaveSyncClient.resolveCheck(localBlobSha: "AAA", lastSyncedSha: "AAA", remoteBlobSha: "AAA"),
            .inSync)
    }

    // Local changed since last sync, remote unchanged → local is strictly ahead → push, no prompt.
    func testLocalAheadPushes() {
        XCTAssertEqual(
            GitHubSaveSyncClient.resolveCheck(localBlobSha: "NEW", lastSyncedSha: "BASE", remoteBlobSha: "BASE"),
            .pushLocal)
    }

    // Remote advanced since last sync and differs from local → offer to load (the Y/N prompt case).
    func testRemoteMovedOffersLoad() {
        XCTAssertEqual(
            GitHubSaveSyncClient.resolveCheck(localBlobSha: "BASE", lastSyncedSha: "BASE", remoteBlobSha: "REMOTE2"),
            .offerLoadRemote)
    }

    // Both sides diverged from the last sync point → still offer to load (host prompts; never silent).
    func testBothDivergedOffersLoad() {
        XCTAssertEqual(
            GitHubSaveSyncClient.resolveCheck(localBlobSha: "LOCAL2", lastSyncedSha: "BASE", remoteBlobSha: "REMOTE2"),
            .offerLoadRemote)
    }

    // Fresh device (no local), hub has a save → offer to load it.
    func testNoLocalOffersLoad() {
        XCTAssertEqual(
            GitHubSaveSyncClient.resolveCheck(localBlobSha: nil, lastSyncedSha: nil, remoteBlobSha: "REMOTE"),
            .offerLoadRemote)
    }

    // Local save, empty hub → seed it.
    func testEmptyHubFirstPush() {
        XCTAssertEqual(
            GitHubSaveSyncClient.resolveCheck(localBlobSha: "LOCAL", lastSyncedSha: nil, remoteBlobSha: nil),
            .firstPush)
    }

    // Neither side has a save → nothing.
    func testNothingEverywhere() {
        XCTAssertEqual(
            GitHubSaveSyncClient.resolveCheck(localBlobSha: nil, lastSyncedSha: nil, remoteBlobSha: nil),
            .nothing)
    }

    // Safety property: a check NEVER silently overwrites a local save. The only actions that can
    // change local are .offerLoadRemote (gated behind the user's Y/N) — never an automatic pull.
    func testNeverSilentlyOverwritesLocal() {
        let local = "LOCALCONTENT"
        for last in ["LOCALCONTENT", "BASE", "other"] {
            for remote in ["LOCALCONTENT", "BASE", "REMOTE2"] {
                let action = GitHubSaveSyncClient.resolveCheck(
                    localBlobSha: local, lastSyncedSha: last, remoteBlobSha: remote)
                // The only non-local-preserving outcome must require a prompt (offerLoadRemote);
                // pushLocal/inSync/firstPush never replace local content behind the user's back.
                switch action {
                case .inSync, .pushLocal, .firstPush, .nothing, .offerLoadRemote:
                    break // all fine: only offerLoadRemote can change local, and only via the prompt
                }
                if action == .inSync { XCTAssertEqual(local, remote) } // inSync ⇒ contents matched
            }
        }
    }
}
