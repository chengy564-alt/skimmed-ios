import Foundation

/// ImportCore — bank detection
///
/// Guesses the issuing bank from cheap, on-device signals so BankConfirmView
/// can lead with "We think this statement is from {Bank}". Signal strengths
/// (strongest wins, no summing — one solid signal beats three weak ones):
///   0.90 filename token ("hsbc_hk.csv")
///   0.85 bank name already found in the file body (ParsedStatement.bankHint)
///   0.80 SWIFT/BIC code in the raw text (HSBCHKHH → HSBC)
///   0.75 known column-header fingerprint (Chase's Transaction/Post/Category/Type set)
///   0.70 bank name anywhere in the raw text
/// Below 0.5 we return nil — an honest "which bank is this?" picker beats a
/// wrong prefill.
public enum BankDetector {

    struct Bank {
        let name: String
        let tokens: [String] // lowercase substrings for filename/body matching
        let bicPrefixes: [String] // 4-letter SWIFT institution codes
        let headerSignature: [String] // lowercase substrings that must ALL appear on one header line
    }

    /// Known institutions. Header signatures mirror each bank's real CSV
    /// export columns; only distinctive combinations qualify (bare
    /// "date,description,amount" identifies nobody).
    static let banks: [Bank] = [
        Bank(name: "HSBC", tokens: ["hsbc"], bicPrefixes: ["HSBC"],
             headerSignature: ["post date", "amount (hkd)"]),
        Bank(name: "Barclays", tokens: ["barclays"], bicPrefixes: ["BARC", "BUKB"],
             headerSignature: ["number", "account", "subcategory", "memo"]),
        Bank(name: "Chase", tokens: ["chase", "jpmorgan", "jp morgan"], bicPrefixes: ["CHAS"],
             headerSignature: ["transaction date", "post date", "category", "type"]),
        Bank(name: "DBS", tokens: ["dbs"], bicPrefixes: ["DBSS"],
             headerSignature: ["transaction date", "reference", "debit amount", "credit amount"]),
        Bank(name: "Hang Seng", tokens: ["hang seng"], bicPrefixes: ["HASE"], headerSignature: []),
        Bank(name: "Standard Chartered", tokens: ["standard chartered"], bicPrefixes: ["SCBL"], headerSignature: []),
        Bank(name: "Citibank", tokens: ["citibank", "citi"], bicPrefixes: ["CITI"], headerSignature: []),
        Bank(name: "Bank of China", tokens: ["bank of china", "bochk"], bicPrefixes: ["BKCH"], headerSignature: []),
        Bank(name: "Monzo", tokens: ["monzo"], bicPrefixes: ["MONZ"], headerSignature: []),
        Bank(name: "Revolut", tokens: ["revolut"], bicPrefixes: ["REVO"], headerSignature: []),
        Bank(name: "American Express", tokens: ["american express", "amex"], bicPrefixes: ["AEIB"], headerSignature: []),
    ]

    /// Best guess across all signals, or nil below the 0.5 floor.
    public static func detect(filename: String, statement: ParsedStatement, rawText: String?) -> BankGuess? {
        var best: BankGuess?
        func offer(_ name: String, _ confidence: Double) {
            if best == nil || confidence > best!.confidence {
                best = BankGuess(name: name, confidence: confidence)
            }
        }

        let fn = filename.lowercased()
        for bank in banks {
            if bank.tokens.contains(where: { fn.contains($0) }) { offer(bank.name, 0.90) }
            if let hint = statement.bankHint, hint.caseInsensitiveCompare(bank.name) == .orderedSame {
                offer(bank.name, 0.85)
            }
        }

        if let rawText {
            let lower = rawText.lowercased()
            // Header fingerprints live in the first few lines (preamble + header).
            let headLines = lower.split(separator: "\n", omittingEmptySubsequences: true)
                .prefix(5).map(String.init)
            for bank in banks {
                if bank.tokens.contains(where: { lower.contains($0) }) { offer(bank.name, 0.70) }
                if !bank.headerSignature.isEmpty,
                   headLines.contains(where: { line in bank.headerSignature.allSatisfy(line.contains) }) {
                    offer(bank.name, 0.75)
                }
            }
            for bic in bicCandidates(in: rawText) {
                let prefix = String(bic.prefix(4))
                if let bank = banks.first(where: { $0.bicPrefixes.contains(prefix) }) {
                    offer(bank.name, 0.80)
                }
            }
        }

        guard let best, best.confidence >= 0.5 else { return nil }
        return best
    }

    /// First known bank name appearing in a line of text (used by
    /// CSVImporter for ParsedStatement.bankHint). Case-insensitive.
    static func bankName(in text: String) -> String? {
        let lower = text.lowercased()
        return banks.first { $0.tokens.contains(where: { lower.contains($0) }) }?.name
    }

    /// SWIFT/BIC shaped tokens: 4 letters (institution) + 2 letters
    /// (country) + 2 alphanumerics (location) + optional 3 (branch). Only
    /// tokens whose institution prefix we recognise matter downstream, so
    /// coincidental all-caps words are harmless.
    static func bicCandidates(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}(?:[A-Z0-9]{3})?\\b"
        ) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
