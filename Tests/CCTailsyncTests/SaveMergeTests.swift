import XCTest
import CommonCrypto
@testable import CCTailsync

/// Tests the save decoder + merge that powers "keep both" on a save conflict.
///
/// We never re-encrypt in production (the merge moves existing encrypted blobs), but the TESTS need to
/// synthesize encrypted saves, so this file has a local CryptoJS-compatible `encrypt` (OpenSSL
/// "Salted__" + AES-256-CBC + MD5 KDF) used ONLY here. Its correctness is pinned by a round-trip:
/// `decrypt(encrypt(x)) == x` through the production `CCSaveCrypto.decrypt`.
final class SaveMergeTests: XCTestCase {

    // MARK: - Test-only CryptoJS encryptor (mirrors CCSaveCrypto's decrypt)

    private func encrypt(_ plaintext: String) -> String {
        var salt = Data(count: 8)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        let (key, iv) = CCSaveCrypto.evpBytesToKey(pass: Data(CCSaveCrypto.passphrase.utf8), salt: salt)
        let pt = Data(plaintext.utf8)
        var out = Data(count: pt.count + kCCBlockSizeAES128)
        let cap = out.count
        var moved = 0
        _ = out.withUnsafeMutableBytes { o in pt.withUnsafeBytes { p in
            key.withUnsafeBytes { k in iv.withUnsafeBytes { i in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, key.count, i.baseAddress,
                        p.baseAddress, pt.count, o.baseAddress, cap, &moved)
            }}}}
        let envelope = Data("Salted__".utf8) + salt + out.prefix(moved)
        return CCSaveCrypto.marker + envelope.base64EncodedString()
    }

    /// Build a slot JSON with the fields the decoder/metadata reads.
    private func slot(area: String, map: String, level: Int, playtime: Double, tag: String = "") -> String {
        let json = """
        {"map":"\(map)","area":{"en_US":"\(area)"},"player":{"level":\(level)},"playtime":\(playtime),"_tag":"\(tag)"}
        """
        return encrypt(json)
    }

    private func save(slots: [String], autoSlot: String?, lastSlot: Int = 0) -> Data {
        var obj: [String: Any] = ["slots": slots, "globals": encrypt("{\"opt\":1}"), "lastSlot": lastSlot]
        if let a = autoSlot { obj["autoSlot"] = a }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Crypto round-trip (pins the decoder against the known format)

    func testDecryptRoundTrip() {
        let original = #"{"hello":"world","n":42}"#
        let field = encrypt(original)
        XCTAssertTrue(CCSaveCrypto.isEncrypted(field))
        guard let back = CCSaveCrypto.decrypt(field) else { return XCTFail("decrypt returned nil") }
        XCTAssertEqual(String(data: back, encoding: .utf8), original)
    }

    func testDecryptRejectsGarbage() {
        XCTAssertNil(CCSaveCrypto.decrypt("not-a-save"))
        XCTAssertNil(CCSaveCrypto.decrypt(CCSaveCrypto.marker + "notbase64!!"))
        XCTAssertNil(CCSaveCrypto.decrypt(CCSaveCrypto.marker + Data("Salted__short".utf8).base64EncodedString()))
    }

    func testContentKeyIsContentNotCiphertext() {
        // Same plaintext, two encryptions (different random salt) → SAME content key (that's the point).
        let a = encrypt(#"{"same":1}"#)
        let b = encrypt(#"{"same":1}"#)
        XCTAssertNotEqual(a, b, "random salt should make ciphertext differ")
        XCTAssertEqual(CCSaveCrypto.contentKey(a), CCSaveCrypto.contentKey(b), "content key must match")
        XCTAssertNotEqual(CCSaveCrypto.contentKey(a), CCSaveCrypto.contentKey(encrypt(#"{"same":2}"#)))
    }

    // MARK: - Metadata

    func testSlotInfoExtraction() {
        let s = slot(area: "Autumn's Rise", map: "autumn.path4", level: 17, playtime: 82080) // 22h48m
        guard let info = CCSave.slotInfo(s, kind: .autosave) else { return XCTFail("no info") }
        XCTAssertEqual(info.kind, .autosave)
        XCTAssertEqual(info.area, "Autumn's Rise")
        XCTAssertEqual(info.map, "autumn.path4")
        XCTAssertEqual(info.level, 17)
        XCTAssertEqual(info.playtimeLabel, "22h48m")
        XCTAssertTrue(info.summary.contains("Autosave"))
        XCTAssertTrue(info.summary.contains("Lv17"))
    }

    // MARK: - Merge semantics

    func testMergeIdenticalAddsNothing() {
        let local = save(slots: [slot(area: "A", map: "m", level: 1, playtime: 10)],
                         autoSlot: slot(area: "A", map: "m", level: 1, playtime: 20))
        // A real "remote == local in content" can't reuse the SAME ciphertext (salt differs), so build a
        // content-identical remote by re-parsing local then re-encrypting its decrypted slots.
        let localObj = try! JSONSerialization.jsonObject(with: local) as! [String: Any]
        let reSlots = (localObj["slots"] as! [String]).map { encryptDecrypted($0) }
        let reAuto = encryptDecrypted(localObj["autoSlot"] as! String)
        let remote = save(slots: reSlots, autoSlot: reAuto)

        guard let r = SaveMerge.merge(localSave: local, remoteSave: remote) else { return XCTFail("merge nil") }
        XCTAssertEqual(r.added.count, 0, "content-identical remote must add nothing")
        let mergedSlots = (try! JSONSerialization.jsonObject(with: r.merged) as! [String: Any])["slots"] as! [String]
        XCTAssertEqual(mergedSlots.count, 1)
    }

    func testMergeAppendsDivergentManualAndAuto() {
        let local = save(slots: [slot(area: "Home", map: "home", level: 5, playtime: 100)],
                         autoSlot: slot(area: "Home", map: "home", level: 5, playtime: 110))
        let remote = save(slots: [slot(area: "Cave", map: "cave", level: 9, playtime: 900, tag: "r")],
                          autoSlot: slot(area: "Cave", map: "cave", level: 9, playtime: 950, tag: "ra"))

        guard let r = SaveMerge.merge(localSave: local, remoteSave: remote) else { return XCTFail("merge nil") }
        XCTAssertEqual(r.added.count, 2, "divergent manual + divergent autosave both appended")
        let slots = (try! JSONSerialization.jsonObject(with: r.merged) as! [String: Any])["slots"] as! [String]
        XCTAssertEqual(slots.count, 3, "1 local + 2 appended")
        // Local autoSlot/globals/lastSlot preserved.
        let obj = try! JSONSerialization.jsonObject(with: r.merged) as! [String: Any]
        XCTAssertNotNil(obj["autoSlot"]); XCTAssertNotNil(obj["globals"])
        XCTAssertEqual(obj["lastSlot"] as? Int, 0)
        // Every merged slot still decrypts (the safety invariant).
        for s in slots { XCTAssertNotNil(CCSaveCrypto.decrypt(s)) }
    }

    func testMergeIsIdempotent() {
        let local = save(slots: [slot(area: "Home", map: "home", level: 5, playtime: 100)],
                         autoSlot: slot(area: "Home", map: "home", level: 5, playtime: 110))
        let remote = save(slots: [slot(area: "Cave", map: "cave", level: 9, playtime: 900)],
                          autoSlot: slot(area: "Cave", map: "cave", level: 9, playtime: 950))
        guard let once = SaveMerge.merge(localSave: local, remoteSave: remote) else { return XCTFail() }
        guard let twice = SaveMerge.merge(localSave: once.merged, remoteSave: remote) else { return XCTFail() }
        XCTAssertEqual(twice.added.count, 0, "re-merging the same remote adds nothing")
        let s1 = (try! JSONSerialization.jsonObject(with: once.merged) as! [String: Any])["slots"] as! [String]
        let s2 = (try! JSONSerialization.jsonObject(with: twice.merged) as! [String: Any])["slots"] as! [String]
        XCTAssertEqual(s1.count, s2.count)
    }

    func testMergeRejectsMalformedInput() {
        let good = save(slots: [slot(area: "A", map: "m", level: 1, playtime: 1)], autoSlot: nil)
        XCTAssertNil(SaveMerge.merge(localSave: Data("not json".utf8), remoteSave: good))
        XCTAssertNil(SaveMerge.merge(localSave: good, remoteSave: Data("{".utf8)))
    }

    func testMergeSkipsUndecodableRemoteSlots() {
        let local = save(slots: [slot(area: "A", map: "m", level: 1, playtime: 1)], autoSlot: nil)
        // Remote carries one good divergent slot and one GARBAGE "slot". Keep-both must NOT silently
        // drop the garbage and then push a save missing it (that would erase a save the user asked to
        // keep). So an undecodable remote slot aborts the whole merge → nil (caller falls back to
        // Load/Keep Mine, leaving the hub copy intact).
        let remoteObj: [String: Any] = [
            "slots": [slot(area: "B", map: "b", level: 2, playtime: 2), "[-!_0_!-]GARBAGE"],
            "globals": "[-!_0_!-]GARBAGE", "lastSlot": 0
        ]
        let remote = try! JSONSerialization.data(withJSONObject: remoteObj)
        XCTAssertNil(SaveMerge.merge(localSave: local, remoteSave: remote),
                     "an undecodable remote slot must abort the merge, never drop-and-push")
    }

    func testMergeSucceedsDespiteUndecodableLocalSlot() {
        // A pre-existing junk slot in the LOCAL save must not block a safe keep-both: the merge never
        // touches local's existing slots, and validation only re-checks the slots it ADDED.
        let localObj: [String: Any] = [
            "slots": [slot(area: "A", map: "m", level: 1, playtime: 1), "[-!_0_!-]PREEXISTING_JUNK"],
            "globals": encrypt("{}"), "lastSlot": 0
        ]
        let local = try! JSONSerialization.data(withJSONObject: localObj)
        let remote = save(slots: [slot(area: "B", map: "b", level: 2, playtime: 2, tag: "r")], autoSlot: nil)
        guard let r = SaveMerge.merge(localSave: local, remoteSave: remote) else { return XCTFail("merge nil") }
        XCTAssertEqual(r.added.count, 1)
        let slots = (try! JSONSerialization.jsonObject(with: r.merged) as! [String: Any])["slots"] as! [String]
        XCTAssertEqual(slots.count, 3, "junk local slot preserved + 1 appended")
    }

    // MARK: - Content identity & cross-device convergence

    func testContentKeysIgnoreSerializationAndOrder() {
        let s1 = slot(area: "A", map: "m", level: 1, playtime: 1)
        let s2 = slot(area: "B", map: "b", level: 2, playtime: 2)
        let auto = slot(area: "C", map: "c", level: 3, playtime: 3)
        // Same saves, different slot ORDER and different serialization → identical content keys.
        let a = save(slots: [s1, s2], autoSlot: auto)
        let bObj: [String: Any] = ["slots": [s2, s1], "autoSlot": auto, "globals": encrypt("{}"), "lastSlot": 1]
        let b = try! JSONSerialization.data(withJSONObject: bObj)
        XCTAssertEqual(CCSave.contentKeys(of: a), CCSave.contentKeys(of: b))
    }

    func testKeepBothConvergesByContent() {
        // The cross-device loop the review caught: phone {A,B,autoP}, hub {A,C,autoH}. After EACH side
        // keep-both merges the other, both hold content {A,B,C,autoP,autoH} — even though their bytes
        // and active autoslots differ. Content keys must then be EQUAL (→ in-sync, no more prompting).
        let A = slot(area: "A", map: "a", level: 1, playtime: 1)
        let B = slot(area: "B", map: "b", level: 2, playtime: 2, tag: "B")
        let C = slot(area: "C", map: "c", level: 3, playtime: 3, tag: "C")
        let autoP = slot(area: "P", map: "p", level: 4, playtime: 4, tag: "P")
        let autoH = slot(area: "H", map: "h", level: 5, playtime: 5, tag: "H")

        let phone = save(slots: [A, B], autoSlot: autoP)
        let hub = save(slots: [A, C], autoSlot: autoH)

        let mergedPhone = SaveMerge.merge(localSave: phone, remoteSave: hub)!.merged   // phone keeps autoP
        let mergedHub = SaveMerge.merge(localSave: hub, remoteSave: phone)!.merged     // PC keeps autoH

        XCTAssertNotEqual(mergedPhone, mergedHub, "bytes/active-autoslot differ by design")
        XCTAssertEqual(CCSave.contentKeys(of: mergedPhone), CCSave.contentKeys(of: mergedHub),
                       "but they must be content-equal so cross-device sync converges (no infinite re-prompt)")
    }

    // Re-encrypt a field's *decrypted content* under a fresh salt (to simulate a content-identical
    // remote with different ciphertext).
    private func encryptDecrypted(_ field: String) -> String {
        let plain = CCSaveCrypto.decrypt(field)!
        return encrypt(String(data: plain, encoding: .utf8)!)
    }

    // MARK: - Client wrappers (file-backed mergeConsent / consentSummaries)

    func testClientMergeConsentWritesAndReports() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saveURL = dir.appendingPathComponent("cc.save")

        let local = save(slots: [slot(area: "Home", map: "home", level: 5, playtime: 100)],
                         autoSlot: slot(area: "Home", map: "home", level: 5, playtime: 110))
        try! local.write(to: saveURL)
        let remote = save(slots: [slot(area: "Cave", map: "cave", level: 9, playtime: 900, tag: "r")],
                          autoSlot: slot(area: "Cave", map: "cave", level: 9, playtime: 950, tag: "ra"))

        // Unconfigured client (no cc-github.json) → mergeConsent still writes locally; push is a no-op.
        let client = GitHubSaveSyncClient(saveFileURL: saveURL,
                                          configURL: dir.appendingPathComponent("cfg.json"),
                                          stateURL: dir.appendingPathComponent("state.json"))

        let summaries = client.consentSummaries(forRemote: remote)
        XCTAssertEqual(summaries.count, 2, "preview lists the divergent manual + autosave")
        XCTAssertTrue(summaries.contains { $0.contains("Cave") && $0.contains("Lv9") })

        guard let merged = client.mergeConsent(remote) else { return XCTFail("mergeConsent nil") }
        // Returned bytes == what's now on disk, and it contains all three slots, all decryptable.
        let onDisk = try! Data(contentsOf: saveURL)
        XCTAssertEqual(merged, onDisk)
        let slots = (try! JSONSerialization.jsonObject(with: merged) as! [String: Any])["slots"] as! [String]
        XCTAssertEqual(slots.count, 3)
        for s in slots { XCTAssertNotNil(CCSaveCrypto.decrypt(s)) }
    }

    func testClientMergeConsentNilWithoutLocalSave() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // No local cc.save on disk → nothing to merge into → nil (and nothing written).
        let client = GitHubSaveSyncClient(saveFileURL: dir.appendingPathComponent("cc.save"),
                                          configURL: dir.appendingPathComponent("cfg.json"),
                                          stateURL: dir.appendingPathComponent("state.json"))
        let remote = save(slots: [slot(area: "Cave", map: "cave", level: 9, playtime: 900)], autoSlot: nil)
        XCTAssertNil(client.mergeConsent(remote))
        XCTAssertEqual(client.consentSummaries(forRemote: remote), [])
    }
}
