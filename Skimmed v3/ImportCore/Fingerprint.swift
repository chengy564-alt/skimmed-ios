import Foundation

/// ImportCore — transaction fingerprints for deduplication
///
/// Re-importing an overlapping statement must not double-count spend, so
/// every imported transaction gets a deterministic fingerprint. Two rows
/// collide exactly when card + date + normalized description + amount +
/// currency all match — which is the definition of a duplicate here. The
/// hash is FNV-1a 64 over a canonical string: stable across launches,
/// devices, and OS versions (unlike Hasher, which is seeded per-process),
/// with no CryptoKit dependency.
public enum Fingerprint {

    /// Fingerprint for a parsed transaction on a given card. `cardID` is the
    /// app-side card identity (imported card UUID), so identical rows on
    /// different cards do NOT collide.
    public static func make(cardID: String, tx: ParsedTransaction) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"

        // Normalize the description so re-exports with different padding
        // ("STARBUCKS  HK" vs "starbucks hk") still dedupe.
        let description = tx.description.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let amount = NSDecimalNumber(decimal: tx.amount).stringValue

        let canonical = [cardID, day.string(from: tx.date), description, amount, tx.currency ?? ""]
            .joined(separator: "|")
        return fnv1aHex(canonical)
    }

    /// FNV-1a 64-bit → 16-char lowercase hex. Internal so
    /// MappingTemplateStore can reuse it for header-signature keys.
    static func fnv1aHex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
