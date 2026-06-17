import XCTest
@testable import CCTailsync

/// Tests the phone-authoritative launch-sync policy: the device's own save is the source of truth
/// and is NEVER overwritten from the server on launch. The only path that adopts the server's save
/// is a device with NO local save (fresh install / restore). This is what prevents the cross-device
/// mtime "newest wins" data-loss footgun.
final class PullPolicyTests: XCTestCase {

    typealias Action = TailscaleSyncClient.PullAction

    // No local save + server has one → first-run seed (the ONLY destructive-to-local path, and there's
    // nothing to lose).
    func testNoLocalSeedsFromServer() {
        XCTAssertEqual(
            TailscaleSyncClient.resolvePull(localSha: nil, remoteExists: true, remoteSha: "abc"),
            .seedFromServer(sha: "abc"))
    }

    // No local save + no server save → nothing to do.
    func testNoLocalNoRemoteIsNoop() {
        XCTAssertEqual(
            TailscaleSyncClient.resolvePull(localSha: nil, remoteExists: false, remoteSha: ""),
            .noRemoteNoLocal)
    }

    // Local save present + server DIFFERS → local wins, push it up. (This is the case the old
    // mtime logic could get wrong and clobber the phone; now it can never pull over a local save.)
    func testLocalDiffersPushesLocalNeverPulls() {
        XCTAssertEqual(
            TailscaleSyncClient.resolvePull(localSha: "fresh", remoteExists: true, remoteSha: "stale"),
            .pushLocal)
    }

    // Local save present + server MISSING → push local up.
    func testLocalPresentRemoteMissingPushesLocal() {
        XCTAssertEqual(
            TailscaleSyncClient.resolvePull(localSha: "fresh", remoteExists: false, remoteSha: ""),
            .pushLocal)
    }

    // Local == server → already in sync, do nothing.
    func testIdenticalIsInSync() {
        XCTAssertEqual(
            TailscaleSyncClient.resolvePull(localSha: "same", remoteExists: true, remoteSha: "same"),
            .inSync)
    }

    // The decisive property: whenever a local save exists, the result is NEVER seedFromServer —
    // i.e. launch can never overwrite on-device progress, regardless of what the server reports.
    func testLocalSaveIsNeverOverwritten() {
        for remoteExists in [true, false] {
            for remoteSha in ["same", "different", ""] {
                let action = TailscaleSyncClient.resolvePull(
                    localSha: "same", remoteExists: remoteExists, remoteSha: remoteSha)
                if case .seedFromServer = action {
                    XCTFail("local save was overwritten (remoteExists=\(remoteExists), remoteSha=\(remoteSha))")
                }
            }
        }
    }
}
