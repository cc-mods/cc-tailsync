import XCTest
@testable import CCTailsync

/// Gated cross-check: proves the Swift decoder reads a REAL CrossCode save (the game's own output),
/// not just data it round-tripped itself. Skipped unless CC_REAL_SAVE points at a real cc.save (so the
/// copyrighted/personal save is never needed in CI and never committed).
final class RealSaveCrossCheck: XCTestCase {
    func testDecodesRealSave() throws {
        guard let path = ProcessInfo.processInfo.environment["CC_REAL_SAVE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw XCTSkip("set CC_REAL_SAVE to a real cc.save to run this cross-check")
        }
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let auto = try XCTUnwrap(obj["autoSlot"] as? String)
        let summary = try XCTUnwrap(CCSave.slotInfo(auto, kind: .autosave))
        print("REAL autoSlot →", summary.summary)
        XCTAssertNotNil(summary.area, "real autoslot must decrypt to a readable area")
        XCTAssertNotNil(summary.level)
        // Every manual slot must decrypt too.
        for slotField in (obj["slots"] as? [String]) ?? [] {
            XCTAssertNotNil(CCSaveCrypto.decrypt(slotField), "real manual slot failed to decrypt")
        }
        // The content-key set must be computable (drives cross-device convergence).
        XCTAssertNotNil(CCSave.contentKeys(of: data))
    }
}
