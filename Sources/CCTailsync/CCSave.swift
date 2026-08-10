import Foundation
import CryptoKit
import CommonCrypto

/// Read-only decoder for CrossCode's `cc.save` save file — enough to (a) compare save *content* for
/// the merge dedup and (b) pull human-readable metadata (area / level / playtime / type) for the
/// conflict prompt. We **never** re-encrypt anything in production: the merge reuses existing
/// encrypted slot strings verbatim, so a decode bug can never corrupt a save.
///
/// ## Save format (reverse-engineered from `game.compiled.js`, verified against a real save)
/// `cc.save` is JSON: `{ "slots": [<slot>...], "autoSlot": <slot>?, "globals": <enc>, "lastSlot": Int }`.
/// `slots` are the **manual** saves; `autoSlot` is the single **autosave** (a separate field — this is
/// how we tell autosave from manual without any crypto). Each `<slot>`/`<enc>` is a string
/// `"[-!_0_!-]" + base64(CryptoJS.AES.encrypt(json, passphrase))`.
///
/// ## Crypto (CryptoJS / OpenSSL "Salted__" envelope)
/// CryptoJS encrypts with a passphrase → `"Salted__" + 8-byte salt + AES-256-CBC ciphertext`, the
/// key+IV derived by OpenSSL's `EVP_BytesToKey` (MD5, 1 iteration). CrossCode's passphrase is the
/// **constant** `":_.NaN0"`: the engine's `encrypt(a,b)` builds `":_." + String(75*b) + (blog()^NaN)`,
/// but every call site (`encryptSlotData`, `getSrc`, globals' `_encrypt`) passes **no** `b`, so
/// `75*undefined → NaN → "NaN"`, `blog()^NaN → 0`, giving `":_." + "NaN" + "0"`. The index is never
/// used, which is also why an encrypted slot blob is portable between files (the basis for the merge).
public enum CCSaveCrypto {
    /// The constant CrossCode save passphrase (see type doc).
    public static let passphrase = ":_.NaN0"

    /// Marker CrossCode prepends to every encrypted field.
    public static let marker = "[-!_0_!-]"

    public static func isEncrypted(_ field: String) -> Bool { field.hasPrefix(marker) }

    /// Decrypt one `"[-!_0_!-]…"` field to its raw JSON bytes, or `nil` if it isn't well-formed.
    public static func decrypt(_ field: String) -> Data? {
        guard field.hasPrefix(marker) else { return nil }
        let b64 = String(field.dropFirst(marker.count))
        guard let raw = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")),
              raw.count > 16,
              raw.prefix(8) == Data("Salted__".utf8) else { return nil }
        let salt = raw.subdata(in: 8..<16)
        let ciphertext = raw.subdata(in: 16..<raw.count)
        let (key, iv) = evpBytesToKey(pass: Data(passphrase.utf8), salt: salt)
        return aesCBCDecryptPKCS7(key: key, iv: iv, ciphertext: ciphertext)
    }

    /// A stable identity for a slot's **decrypted content**, used to dedup across files. Encrypted
    /// bytes can't be compared directly (a random salt makes identical saves encrypt differently), so
    /// we hash the plaintext. `nil` if the field can't be decrypted.
    public static func contentKey(_ field: String) -> String? {
        guard let plain = decrypt(field) else { return nil }
        return SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Primitives

    /// OpenSSL `EVP_BytesToKey` with MD5, 1 iteration → (32-byte key, 16-byte IV) for AES-256-CBC.
    static func evpBytesToKey(pass: Data, salt: Data, keyLen: Int = 32, ivLen: Int = 16) -> (Data, Data) {
        var derived = Data()
        var block = Data()
        while derived.count < keyLen + ivLen {
            var md5 = Insecure.MD5()
            md5.update(data: block)
            md5.update(data: pass)
            md5.update(data: salt)
            block = Data(md5.finalize())
            derived.append(block)
        }
        return (derived.prefix(keyLen), derived.subdata(in: keyLen..<(keyLen + ivLen)))
    }

    /// AES-256-CBC decrypt with PKCS7 padding (CommonCrypto). `nil` on any failure.
    static func aesCBCDecryptPKCS7(key: Data, iv: Data, ciphertext: Data) -> Data? {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128,
              !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }
        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            ciphertext.withUnsafeBytes { ctBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBuf.baseAddress, key.count,
                                ivBuf.baseAddress,
                                ctBuf.baseAddress, ciphertext.count,
                                outBuf.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }
}

/// Human-readable summary of one save slot, for the conflict prompt and the merge report.
public struct CCSaveSlotInfo: Equatable {
    public enum Kind: String, Equatable { case manual, autosave }
    public let kind: Kind
    public let area: String?        // localized area name (en_US), e.g. "Autumn's Rise"
    public let map: String?         // internal map id, e.g. "autumn.path4"
    public let level: Int?          // player level
    public let playtimeSeconds: Double?

    /// Compact playtime like "22h48m" (or "—" when unknown).
    public var playtimeLabel: String {
        guard let s = playtimeSeconds, s >= 0 else { return "—" }
        let total = Int(s)
        return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))m"
    }

    /// One-line label for a menu/alert, e.g. "Autosave · Autumn's Rise · Lv17 · 22h48m".
    public var summary: String {
        var parts: [String] = [kind == .autosave ? "Autosave" : "Manual save"]
        if let a = area ?? map { parts.append(a) }
        if let l = level { parts.append("Lv\(l)") }
        parts.append(playtimeLabel)
        return parts.joined(separator: " · ")
    }
}

public enum CCSave {
    /// Decode a slot's metadata for display. `kind` distinguishes the autosave from manual saves.
    public static func slotInfo(_ field: String, kind: CCSaveSlotInfo.Kind) -> CCSaveSlotInfo? {
        guard let data = CCSaveCrypto.decrypt(field),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let area: String? = {
            if let a = obj["area"] as? [String: Any], let en = a["en_US"] as? String { return en }
            return obj["area"] as? String
        }()
        let level = (obj["player"] as? [String: Any])?["level"] as? Int
        let playtime = obj["playtime"] as? Double ?? (obj["playtime"] as? NSNumber)?.doubleValue
        return CCSaveSlotInfo(kind: kind, area: area, map: obj["map"] as? String,
                              level: level, playtimeSeconds: playtime)
    }

    /// The set of decrypted-content identities of every save inside a `cc.save` (manual slots **plus**
    /// the autosave). This is the file's *content* independent of serialization, slot order, or which
    /// save happens to be the active autoslot — so two `cc.save` files that hold the same saves compare
    /// equal even when their bytes differ. That's what lets cross-device "Keep Both" converge instead
    /// of conflicting forever (the phone and the PC serialize JSON differently and each keeps its own
    /// autoslot, so byte equality never holds; content equality does). Returns `nil` if the file isn't
    /// parseable. Undecodable individual slots are skipped (they have no content identity).
    public static func contentKeys(of saveData: Data) -> Set<String>? {
        guard let obj = try? JSONSerialization.jsonObject(with: saveData) as? [String: Any] else { return nil }
        var keys = Set<String>()
        for s in (obj["slots"] as? [String]) ?? [] {
            if let k = CCSaveCrypto.contentKey(s) { keys.insert(k) }
        }
        if let auto = obj["autoSlot"] as? String, let k = CCSaveCrypto.contentKey(auto) { keys.insert(k) }
        return keys
    }
}
