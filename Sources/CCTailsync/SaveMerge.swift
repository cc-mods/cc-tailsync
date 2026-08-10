import Foundation

/// Non-destructive merge of a diverging remote `cc.save` into the local one, so BOTH saves survive a
/// conflict and the player can pick/delete the bad one in CrossCode's own Load menu — instead of one
/// silently clobbering the other.
///
/// ## How it stays safe
/// CrossCode's per-slot key ignores the slot index (see `CCSaveCrypto`), so an **encrypted slot blob
/// is portable** between files. The merge therefore only ever *moves existing encrypted strings* — it
/// **never re-encrypts**, so it cannot corrupt a slot. The remote's divergent manual slots, plus its
/// autosave (surfaced as a manual slot so it's visible/loadable), are appended to the local `slots[]`.
/// Local `autoSlot`, `globals`, and `lastSlot` are kept as-is (phone-authoritative): your active save
/// and global flags don't change — you just gain the conflicting saves as extra slots to inspect.
///
/// Dedup is by **decrypted content** (a random salt makes identical saves encrypt to different bytes),
/// so re-merging the same remote adds nothing (idempotent). The result is **validated before return**
/// (re-parsed, and every slot re-decrypted); if anything looks wrong we return `nil` and the caller
/// leaves the local save untouched.
public enum SaveMerge {

    public struct Result {
        /// The merged `cc.save` bytes, ready to write atomically. Empty merge (nothing to add) still
        /// returns the (re-serialized, validated) local save and `added == []`.
        public let merged: Data
        /// Metadata for each slot that was appended — drives the "kept N conflicting saves" prompt.
        public let added: [CCSaveSlotInfo]
    }

    /// Merge `remoteSave` into `localSave`. Returns `nil` if either input is malformed, if any remote
    /// slot can't be decoded (we then refuse to keep-both rather than risk silently dropping — and
    /// later erasing from the hub — a save we couldn't read; the caller falls back to Load/Keep Mine,
    /// leaving the hub copy intact), or if the merged result fails structural validation.
    public static func merge(localSave: Data, remoteSave: Data) -> Result? {
        guard var local = parse(localSave), let remote = parse(remoteSave) else { return nil }
        var slots = (local["slots"] as? [String]) ?? []

        // Content keys already present locally (manual slots + the local autosave) → never re-add them.
        // A pre-existing local slot we can't decode is simply not in the dedup set; we never touch
        // local's existing slots, so it passes through untouched.
        var seen = Set<String>()
        for s in slots { if let k = CCSaveCrypto.contentKey(s) { seen.insert(k) } }
        if let auto = local["autoSlot"] as? String, let k = CCSaveCrypto.contentKey(auto) { seen.insert(k) }

        var added: [String] = []      // the encrypted blobs we appended (to validate only these)
        var addedInfo: [CCSaveSlotInfo] = []

        /// Try to take one remote field (manual slot or its autosave) — returns false to ABORT the
        /// whole merge if it can't be decoded (keep-both must never silently lose a save).
        func take(_ field: String, kind: CCSaveSlotInfo.Kind) -> Bool {
            guard let k = CCSaveCrypto.contentKey(field) else { return false } // undecodable → abort
            if seen.insert(k).inserted {
                slots.append(field)
                added.append(field)
                if let info = CCSave.slotInfo(field, kind: kind) { addedInfo.append(info) }
            }
            return true
        }

        for s in (remote["slots"] as? [String]) ?? [] {
            if !take(s, kind: .manual) { return nil }
        }
        if let remoteAuto = remote["autoSlot"] as? String {
            if !take(remoteAuto, kind: .autosave) { return nil }
        }

        local["slots"] = slots
        guard let out = serialize(local), validate(out, addedSlots: added) else { return nil }
        return Result(merged: out, added: addedInfo)
    }

    // MARK: - Helpers

    private static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func serialize(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj)
    }

    /// A merged save is acceptable only if it re-parses, has a slots array, `lastSlot` is intact, and
    /// every slot WE ADDED decrypts to JSON. We deliberately validate only the added slots, not the
    /// pre-existing local ones: the merge never alters local's existing slots (it appends verbatim
    /// encrypted blobs), so a pre-existing quirk in the local save must not block a safe keep-both —
    /// and re-validating bytes we copied verbatim from a save the user is already playing adds nothing.
    static func validate(_ data: Data, addedSlots: [String]) -> Bool {
        guard let obj = parse(data),
              let slots = obj["slots"] as? [String] else { return false }
        guard obj["lastSlot"] is Int || obj["lastSlot"] is NSNumber else { return false }
        let addedSet = Set(addedSlots)
        for s in slots where addedSet.contains(s) {
            guard let plain = CCSaveCrypto.decrypt(s),
                  (try? JSONSerialization.jsonObject(with: plain)) != nil else { return false }
        }
        return true
    }
}
