import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// ImportCore — PDF statement extraction
///
/// PDFs are the low-confidence path: there is no column structure, only a
/// text layer (when one exists at all). Real bank statements routinely wrap
/// one transaction across several lines (merchant on the date line, location
/// on the next, amount on a third — sometimes with a running-balance column
/// tacked on the end), so mining is RECORD-based: a record starts at a
/// date-led line and absorbs every following non-date-led line as
/// description, until an amount-shaped token closes it off (or the next
/// date-led line starts a new record). Several transactions can share one
/// printed date — each amount token closes its own record. Everything
/// doubtful lands in `warnings`, never as a malformed row. Scanned PDFs (no
/// extractable text) throw `.unreadable` so the UI can say "export a CSV
/// instead".
///
/// PDFKit exists on both iOS and macOS, so `swift test` exercises the real
/// path; the `#else` fallback only keeps the file compiling on platforms
/// without PDFKit and honestly refuses.
public enum PDFStatementImporter {

    #if canImport(PDFKit)
    /// Open the PDF, pull the text layer page by page, and mine it.
    /// `.unreadable`: fails to open, or opens with no extractable text.
    /// `.empty`: text extracted fine but no line matched a transaction.
    public static func parse(data: Data, filename: String) throws -> ParsedStatement {
        guard let document = PDFDocument(data: data) else { throw ImportError.unreadable }
        var text = ""
        for i in 0..<document.pageCount {
            if let pageText = document.page(at: i)?.string {
                text += pageText
                text += "\n"
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.unreadable // opened, but no text layer — a scan
        }
        return try parse(text: text, filename: filename)
    }
    #else
    /// No PDFKit on this platform — refuse honestly rather than guess.
    public static func parse(data: Data, filename: String) throws -> ParsedStatement {
        throw ImportError.unreadable
    }
    #endif

    // MARK: - Line patterns

    /// Date token at the start of a line. Strict on purpose: ISO, 4-digit-year
    /// slash/dot numerics, or "d MMM yyyy". Two-digit years don't qualify —
    /// better to skip a line than invent year 26 AD.
    static let dateHead: NSRegularExpression = {
        let iso = #"\d{4}-\d{2}-\d{2}"#
        let slashOrDot = #"\d{1,2}([./])\d{1,2}\1\d{4}"#
        let monthName = #"\d{1,2}\s+[A-Za-z]{3,9}\.?,?\s+\d{4}"#
        return try! NSRegularExpression(pattern: "^(?:\(iso)|\(slashOrDot)|\(monthName))\\b")
    }()

    /// Date token that also accepts a 2-digit year ("23 Dec 25", "12 Jan 26")
    /// — real UK statements print short years this way throughout. Used to
    /// recognise record boundaries; `expandTwoDigitYear` below normalizes the
    /// captured token to a 4-digit year before it ever reaches
    /// `CSVImporter.inferDateStyle`/`parseDate` (which rightly reject 2-digit
    /// years from CSV columns — there the ambiguity is real; here the
    /// statement's own period header disambiguates the century, so this file
    /// resolves it once rather than pushing an unresolvable case downstream).
    static let dateHeadLoose: NSRegularExpression = {
        let iso = #"\d{4}-\d{2}-\d{2}"#
        let slashOrDot = #"\d{1,2}([./])\d{1,2}\1\d{2,4}"#
        let monthName = #"\d{1,2}\s+[A-Za-z]{3,9}\.?,?\s+\d{2,4}"#
        return try! NSRegularExpression(pattern: "^(?:\(iso)|\(slashOrDot)|\(monthName))\\b")
    }()

    /// "23 Dec 25" → "23 Dec 2025", "23/12/25" → "23/12/2025". ISO tokens and
    /// already-4-digit-year tokens pass through unchanged — the fixed `{2}`
    /// quantifier anchored to `$` only matches when exactly two digits
    /// remain after the day/month prefix, which a real 4-digit year never
    /// satisfies (it always leaves 4). Assumes the 2000s: nobody is
    /// importing a 1920s bank statement.
    static let twoDigitYearPattern = try! NSRegularExpression(
        pattern: #"^(\d{1,2}\s+[A-Za-z]{3,9}\.?,?\s+|\d{1,2}[./]\d{1,2}[./])(\d{2})$"#
    )
    static func expandTwoDigitYear(_ token: String) -> String {
        let ns = token as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = twoDigitYearPattern.firstMatch(in: token, range: full) else { return token }
        let prefix = ns.substring(with: m.range(at: 1))
        let yy = ns.substring(with: m.range(at: 2))
        return prefix + "20" + yy
    }

    /// A settled amount ANYWHERE in a line: requires a decimal separator with
    /// exactly two decimals (the strictness gate — reference numbers and years
    /// never look like "1,234.56"). Optional currency symbol/code prefix,
    /// parentheses, leading minus; optional trailing CR/DR marker captured
    /// separately so a caller can decide what to do with it. Unlike the old
    /// end-anchored pattern this scans the whole line — multi-line records
    /// can carry the amount and a running balance on the SAME physical line
    /// ("HELP.UBER.COM 20.26 486.64"), and this needs to find both in order.
    /// The trailing `(?!\d)` is load-bearing: without it, a plain grouped
    /// integer with no decimal tail at all ("JPY 12,300") backtracks into a
    /// false decimal split ("12,30" + stray "0") because the scan isn't
    /// anchored to line-end the way the old single-line pattern was. Refusing
    /// a decimal match immediately followed by another digit closes that gap.
    /// The space-grouped-thousands alternative ("1 234,56") is gated behind a
    /// currency symbol for the same reason: unanchored, a bare space-grouped
    /// number can straddle two UNRELATED tokens (a foreign amount's leftover
    /// digits followed by the real trailing amount, e.g. "JPY 12,300 678.45"
    /// misreading as "300 678.45") — a leading symbol is what makes it safe
    /// to trust the space as a grouping separator rather than a line break.
    /// `(?!%)` matters just as much as `(?!\d)`: the boilerplate/rates section
    /// every real UK statement carries after the last transaction ("Credit
    /// interest is not paid upto 25 0.00%", "over 25 39.90%") is otherwise a
    /// field of 2-decimal-shaped numbers with no date to bound the scan —
    /// they'd be mined as spend. A trailing amount is never a percentage.
    static let amountAny: NSRegularExpression = try! NSRegularExpression(
        pattern: #"(\(?\s*-?\s*(?:[$€£¥]\s*\d{1,3}(?: \d{3})+|[$€£¥]?\s*\d[\d.,]*)[.,]\d{2}(?!\d)(?!%)\s*\)?)(\s*(?:CR|DR))?"#,
        options: [.caseInsensitive]
    )

    /// Description-region keywords that mark a record as a balance/total footer
    /// rather than a transaction ("30 Jun 2026 CLOSING BALANCE 12,345.67",
    /// "… BROUGHT FORWARD 8,000.00"). Matched against a WHITESPACE-STRIPPED,
    /// lowercased copy of the record text (see `matchesBalanceKeyword`) — real
    /// bank-exported PDFs sometimes kern-split words across an extra space
    /// ("BAL ANCE CARRI ED FORWARD"), which would dodge a plain substring
    /// check. Deliberately loose enough to also catch a real merchant like
    /// "TOTAL Energies petrol"; given the strictness philosophy here (doubt →
    /// never a malformed row) that false positive is an acceptable tradeoff
    /// against silently importing a running total as spend.
    static let balanceLineKeywords: [String] = [
        "balance", "total", "brought forward", "carried forward", "b/f", "c/f",
        // Bank-account statement furniture (HSBC One portfolio pages):
        // summary tables full of balances/rates that must never mine as spend.
        "net position", "portfolio", "exchange rate", "summary", "equivalent",
        "average", "relationship", "savings", "current account", "hkd current",
    ]

    /// Column-header phrases that mean this statement prints a running
    /// Balance column alongside Paid out/in (or Money/Withdrawals/Deposits).
    /// When present, a record whose final line carries two trailing amount
    /// tokens is read as "amount, then balance" (take the first, drop the
    /// second) instead of being an automatic warn-and-skip — see
    /// `balanceHeaderDetected` below.
    static let balanceHeaderPhrases: [String] = [
        "paid out", "paid in", "money out", "money in", "withdrawal", "deposit",
    ]

    /// Leading transaction-type codes UK/HSBC-style statements print instead
    /// of repeating the date — this is what lets several transactions share
    /// one printed date ("12 Jan 26 VIS AMZNMktplace…" then, undated,
    /// "VIS AMAZON* …", "))) BOOTS 1979 …" as separate purchases below it).
    /// Case-sensitive: these are literal bank-statement abbreviations, not
    /// prose. `outbound` codes are debit-side by definition (card purchase,
    /// direct debit, standing order, cash withdrawal, bill payment, cheque,
    /// transfer, contactless icon); `inbound` are credit-side (an incoming
    /// credit reference, bank giro credit, faster payment in, a refund).
    /// A record whose leading token matches neither list still defaults
    /// spend-positive (never fabricate a direction we can't see) but earns a
    /// warning IF this statement has a balance header — meaning a genuine
    /// Paid-in/Paid-out ambiguity exists that the marker didn't resolve.
    static let outboundMarkers: Set<String> = ["VIS", ")))", "DD", "SO", "ATM", "BP", "CHQ", "TFR", "DEB", "POS"]
    static let inboundMarkers: Set<String> = ["CR", "BGC", "FPI", "REFUND"]

    /// Original foreign amount inside a description: an ISO 4217 code we
    /// recognise followed by a number ("JPY 12,300", "GBP 210.40"). The
    /// whitelist keeps random capitalised words from matching.
    static let foreignAmount: NSRegularExpression = try! NSRegularExpression(
        pattern: #"\b([A-Z]{3})\s+(\d[\d.,]*\d|\d)\b"#
    )

    /// Common ISO 4217 codes for the foreign-amount whitelist. Deliberately
    /// broad but closed — an unknown triple stays in the description text.
    static let knownCurrencies: Set<String> = [
        "USD", "EUR", "GBP", "JPY", "CNY", "HKD", "TWD", "KRW", "SGD", "MYR",
        "THB", "IDR", "PHP", "VND", "INR", "AUD", "NZD", "CAD", "CHF", "SEK",
        "NOK", "DKK", "PLN", "CZK", "HUF", "TRY", "AED", "SAR", "QAR", "ILS",
        "ZAR", "BRL", "MXN", "ARS", "CLP", "COP", "PEN", "MOP", "LKR", "BDT",
        "PKR", "NPR", "KHR", "LAK", "MMK", "BND", "FJD", "ISK", "RON", "BGN",
    ]

    // MARK: - Text mining

    /// Mine extracted PDF text: candidate records are gathered first so the
    /// document-wide date style and decimal-comma mode are decided once (same
    /// approach as CSVImporter's per-column inference), then parsed.
    static func parse(text: String, filename: String) throws -> ParsedStatement {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var warnings: [String] = []

        // Whole-document signal: does this statement print a running Balance
        // column alongside Paid out/Paid in (or Money/Withdrawals/Deposits)?
        // Scanned across every line (not just the header region) because
        // multi-page statements often repeat the column caption per page.
        // Tightened on purpose: loose prose like "make a deposit to grow your
        // balance" contains "balance" + "deposit" too, and must NOT flip take-
        // first mode. A genuine column header either sits on a line that also
        // says "date"/"description" (the real-file case: "Date Description
        // Paid out Paid in Balance"), or names at least two distinct column
        // phrases on the same line (e.g. "Paid out Paid in Balance" with no
        // "Date" token, still clearly tabular) — marketing text names at most one.
        let balanceHeaderDetected: Bool = lines.contains { line in
            let lower = line.lowercased()
            guard lower.contains("balance") else { return false }
            let matchedPhrases = balanceHeaderPhrases.filter { lower.contains($0) }
            guard !matchedPhrases.isEmpty else { return false }
            if lower.contains("date") || lower.contains("description") { return true }
            return matchedPhrases.count >= 2
        }

        struct Candidate {
            let raw: String
            let dateToken: String
            let leadingToken: String // first word of the record — for outbound/inbound marker matching
            let middle: String
            let amountToken: String
            let ambiguousDirection: Bool
        }

        var candidates: [Candidate] = []
        var firstTransactionLine = lines.count

        // MARK: Record accumulation state

        var currentDateToken: String?
        var currentDateLineIndex = 0
        var pendingText: [String] = [] // description lines accumulated since the last segment cut
        var pendingClose: (dateToken: String, lead: String, middle: String)?
        // Did the CURRENT date-group already close at least one segment?
        // Once it has, leftover trailing text with no amount (page-footer
        // furniture like "Page 1 of 1") is silently dropped rather than
        // warned — the block already proved it was real transaction data,
        // so more text with no amount reads as document noise, not a doubt.
        // A date-group that never closes a single segment IS a doubt
        // ("19 Jun 2026 FEE ADJUSTMENT SEE NOTE 3", no amount anywhere).
        var blockHadAmount = false

        func leadingToken(of text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let ns = trimmed.split(separator: " ").first else { return "" }
            return String(ns)
        }

        /// Turn accumulated text + a closing amount into a Candidate, applying
        /// the balance/total-row guard and appending it (or a warning) as
        /// appropriate. `prefixOnClosingLine` is the piece of the closing
        /// line that precedes the amount token — it belongs to this segment's
        /// description too.
        func closeSegment(prefixOnClosingLine: String) {
            guard let dateToken = currentDateToken else { pendingText = []; return }
            var descLines = pendingText
            let trimmedPrefix = prefixOnClosingLine.trimmingCharacters(in: .whitespaces)
            if !trimmedPrefix.isEmpty { descLines.append(trimmedPrefix) }
            let rawMiddle = descLines.joined(separator: " ")
            let lead = descLines.first.map(leadingToken) ?? leadingToken(of: dateToken)
            pendingClose = (dateToken, lead, rawMiddle)
            pendingText = []
        }

        func emit(amountToken: String, rawLine: String) {
            guard let pending = pendingClose else { return }
            pendingClose = nil
            blockHadAmount = true
            var middle = pending.middle
            // Strip contactless/noise markers and collapse whitespace.
            middle = middle.replacingOccurrences(of: "\\)\\)\\)", with: " ", options: .regularExpression)
            middle = middle.split(separator: " ").joined(separator: " ")
            guard !middle.isEmpty else {
                warnings.append("Skipped record (no description): \"\(rawLine)\"")
                return
            }

            // Balance/total footer records ("BALANCE BROUGHT FORWARD 8,000.00",
            // even kern-split as "BAL ANCE BROUGHT FORWARD") are not spend —
            // route to warnings instead of mining them as transactions.
            let despaced = middle.lowercased().replacingOccurrences(of: " ", with: "")
            if balanceLineKeywords.contains(where: { despaced.contains($0.replacingOccurrences(of: " ", with: "")) }) {
                // `middle` (the joined, cleaned description) carries the
                // context that matters here — a multi-line record's closing
                // line alone (`rawLine`) is often just the bare amount.
                warnings.append("Skipped record (balance/total row): \"\(middle)\"")
                return
            }

            let ambiguous = !outboundMarkers.contains(pending.lead) && !inboundMarkers.contains(pending.lead)
            candidates.append(Candidate(
                raw: rawLine, dateToken: pending.dateToken, leadingToken: pending.lead,
                middle: middle, amountToken: amountToken,
                ambiguousDirection: ambiguous && balanceHeaderDetected
            ))
            firstTransactionLine = min(firstTransactionLine, currentDateLineIndex)
        }

        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            if let dateMatch = dateHeadLoose.firstMatch(in: line, range: full) {
                // A new date-led line: flush any dangling accumulation from
                // the previous date-group. Only a doubt if that group never
                // closed a single segment — otherwise it's trailing furniture.
                if currentDateToken != nil, !pendingText.isEmpty, !blockHadAmount {
                    warnings.append("Skipped record (no amount found): \"\(pendingText.joined(separator: " "))\"")
                }
                pendingText = []
                blockHadAmount = false
                currentDateToken = expandTwoDigitYear(ns.substring(with: dateMatch.range))
                currentDateLineIndex = index
                let remainder = ns.substring(from: dateMatch.range.length)
                processLineBody(remainder, rawLine: line)
                continue
            }

            guard currentDateToken != nil else { continue } // header/footer furniture before any date
            processLineBody(line, rawLine: line)
        }
        if currentDateToken != nil, !pendingText.isEmpty, !blockHadAmount {
            warnings.append("Skipped record (no amount found): \"\(pendingText.joined(separator: " "))\"")
        }

        /// Process one physical line's worth of text once we know it belongs
        /// to a record (either the remainder of a date-led line, or a bare
        /// continuation line). Finds every amount-shaped token on the line,
        /// in order, and closes a segment at each one — several
        /// undated transactions can share a single printed date, each ending
        /// at its own amount.
        func processLineBody(_ body: String, rawLine: String) {
            let bodyNS = body as NSString
            let bodyRange = NSRange(location: 0, length: bodyNS.length)
            let matches = amountAny.matches(in: body, range: bodyRange)
            guard !matches.isEmpty else {
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { pendingText.append(trimmed) }
                return
            }

            if matches.count >= 2 {
                // Genuine foreign-amount rows also end with a number in the
                // description ("AIRBNB LONDON GBP 210.40 2,105.33" — GBP
                // 210.40 is the original, 2,105.33 the settled amount/
                // balance). When every non-final match is immediately
                // preceded by a recognised ISO currency code, this is that
                // case, not a running-balance duplicate: the LAST match is
                // the record's amount, everything earlier stays in the
                // description for `firstForeignAmount` to mine out later.
                let allEarlierAreForeignOriginals = matches.dropLast().allSatisfy { m in
                    let before = bodyNS.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
                    let lastWord = before.split(separator: " ").last.map(String.init) ?? ""
                    return knownCurrencies.contains(lastWord)
                }
                if allEarlierAreForeignOriginals {
                    let lastMatch = matches.last!
                    let prefix = bodyNS.substring(to: lastMatch.range.location)
                    closeSegment(prefixOnClosingLine: prefix)
                    var amountToken = bodyNS.substring(with: lastMatch.range(at: 1))
                    if lastMatch.range(at: 2).location != NSNotFound {
                        amountToken += " " + bodyNS.substring(with: lastMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    }
                    emit(amountToken: amountToken, rawLine: rawLine)
                    let after = bodyNS.substring(from: lastMatch.range.location + lastMatch.range.length)
                        .trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty { pendingText = [after] }
                    return
                }

                // Running-balance layouts print an amount AND a balance on
                // the same line ("STARBUCKS CENTRAL 48.00  1,282.45"). When a
                // Balance column was announced in the header, the FIRST token
                // is the transaction amount and the trailing one(s) are the
                // balance — drop them. Without that header to justify it,
                // stay conservative: warn and skip, exactly as the old
                // single-line guard did.
                if !balanceHeaderDetected {
                    let whole = (pendingText + [bodyNS.substring(to: matches.last!.range.location)
                        .trimmingCharacters(in: .whitespaces)]).joined(separator: " ")
                    warnings.append("Skipped record (running-balance column, two trailing amounts): \"\(whole) \(rawLine)\"")
                    pendingText = []
                    pendingClose = nil
                    return
                }
                // Close a segment at every match except the last (the balance).
                var cursor = 0
                for match in matches.dropLast() {
                    let prefix = bodyNS.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    closeSegment(prefixOnClosingLine: prefix)
                    var amountToken = bodyNS.substring(with: match.range(at: 1))
                    if match.range(at: 2).location != NSNotFound {
                        amountToken += " " + bodyNS.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    }
                    emit(amountToken: amountToken, rawLine: rawLine)
                    cursor = match.range.location + match.range.length
                }
                // Trailing balance token is discarded; nothing after it
                // (rare) becomes the start of the NEXT segment's text.
                let lastMatch = matches.last!
                let after = bodyNS.substring(from: lastMatch.range.location + lastMatch.range.length)
                    .trimmingCharacters(in: .whitespaces)
                if !after.isEmpty { pendingText = [after] }
                return
            }

            // Exactly one amount on this line. Usually it closes the current
            // segment — UNLESS the token immediately preceding it is a known
            // ISO currency code, meaning this is a foreign ORIGINAL amount
            // printed alone on a continuation line ("USD 1.00 @ 1.3333" with
            // the real settled amount still to come on a later line). That is
            // exactly the same-line exception above
            // (`allEarlierAreForeignOriginals`) extended across the line
            // break: without it, this lone "1.00" would wrongly close the
            // segment and import as its own tiny spend row, while the
            // leftover "@ 1.3333" leaked into the NEXT record's description.
            // Instead, fold the whole line into the still-open description
            // and keep waiting for the real closing amount; `firstForeignAmount`
            // mines the original back out once the record finally closes. If
            // no settled amount ever arrives, the existing dangling-block
            // check (below / at the next date-led line) turns this into a
            // warning rather than a fabricated row.
            let match = matches[0]
            let prefix = bodyNS.substring(to: match.range.location)
            let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
            let precedingWord: String
            if let lastWord = trimmedPrefix.split(separator: " ").last {
                precedingWord = String(lastWord)
            } else {
                precedingWord = pendingText.last?.split(separator: " ").last.map(String.init) ?? ""
            }
            if knownCurrencies.contains(precedingWord) {
                let whole = body.trimmingCharacters(in: .whitespaces)
                if !whole.isEmpty { pendingText.append(whole) }
                return
            }
            closeSegment(prefixOnClosingLine: prefix)
            var amountToken = bodyNS.substring(with: match.range(at: 1))
            if match.range(at: 2).location != NSNotFound {
                amountToken += " " + bodyNS.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            }
            emit(amountToken: amountToken, rawLine: rawLine)
            let after = bodyNS.substring(from: match.range.location + match.range.length)
                .trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { pendingText = [after] }
        }

        // Header region = everything above the first transaction line.
        let headerLines = Array(lines.prefix(firstTransactionLine))

        guard !candidates.isEmpty else {
            // Text extracted fine; it just isn't (or doesn't contain) a statement.
            throw ImportError.empty
        }

        // Document-wide inference, reusing CSVImporter's helpers. Only
        // 4-digit-year dates are trusted to resolve (dateHeadLoose above
        // accepted 2-digit years just to find record boundaries).
        let (dateStyle, dateWarning) = CSVImporter.inferDateStyle(candidates.map { $0.dateToken })
        if let dateWarning { warnings.append(dateWarning) }
        let dateFormatter = CSVImporter.makeDateFormatter(dateStyle)
        let commaDecimal = CSVImporter.usesCommaDecimal(candidates.map { $0.amountToken })

        var transactions: [ParsedTransaction] = []
        for c in candidates {
            guard let date = CSVImporter.parseDate(c.dateToken, style: dateStyle, formatter: dateFormatter) else {
                warnings.append("Skipped record (unrecognised date \"\(c.dateToken)\"): \"\(c.raw)\"")
                continue
            }
            guard var amount = CSVImporter.parseAmount(c.amountToken, commaDecimal: commaDecimal) else {
                warnings.append("Skipped record (unreadable amount \"\(c.amountToken)\"): \"\(c.raw)\"")
                continue
            }
            // Card/bank PDF statements print spend as plain positive and money
            // in as CR/minus/(parens) on the amount itself — parseAmount
            // already returns those negative. A LEADING transaction-type
            // code ("CR 1/MRS WONG…") is a separate signal: it means this
            // whole record is a credit even though its own amount token has
            // no CR/DR suffix. Never both — parseAmount's suffix already won
            // if present; only flip for the leading-marker case when the
            // amount came back positive (a suffix-negative amount is already
            // handled).
            if inboundMarkers.contains(c.leadingToken), amount > 0 {
                amount = -amount
            }
            if c.ambiguousDirection {
                warnings.append("Assumed paid out (spend) — couldn't confirm against the Paid in/out columns: \"\(c.raw)\"")
            }

            var description = c.middle
            var originalAmount: Decimal?
            var originalCurrency: String?
            if let (code, value, range) = firstForeignAmount(in: description, commaDecimal: commaDecimal) {
                originalCurrency = code
                originalAmount = amount < 0 ? -abs(value) : abs(value) // inherits amount's sign
                let ns = description as NSString
                description = (ns.substring(to: range.location) + " " + ns.substring(from: range.location + range.length))
                    .split(separator: " ").joined(separator: " ")
            }
            guard !description.isEmpty else {
                warnings.append("Skipped record (no description): \"\(c.raw)\"")
                continue
            }
            transactions.append(ParsedTransaction(
                date: date,
                description: description,
                amount: amount,
                currency: nil, // per-row currency columns don't exist in PDF text
                originalAmount: originalAmount,
                originalCurrency: originalCurrency,
                cardLast4: nil,
                rawLine: c.raw
            ))
        }
        guard !transactions.isEmpty else { throw ImportError.empty }

        // --- Header-region metadata ---

        // Bank hint: same normalization path BankDetector uses everywhere.
        var bankHint: String?
        for line in headerLines {
            if let name = BankDetector.bankName(in: line) { bankHint = name; break }
        }
        if bankHint == nil { bankHint = BankDetector.bankName(in: filename) }

        // Account/card last 4: keyworded header lines, same rule as CSV preamble.
        var accountLast4: String?
        for line in headerLines {
            let lower = line.lowercased()
            if lower.contains("ending") || lower.contains("card") || lower.contains("account")
                || line.contains("****"),
               let l4 = CSVImporter.extractLast4(line) {
                accountLast4 = l4
                break
            }
        }

        // Statement currency: "(HKD)" style header, or a currency keyword
        // followed by a known code ("All amounts in HKD", "Currency: HKD").
        var statementCurrency: String?
        for line in headerLines {
            if let code = CSVImporter.currencyCode(inHeader: line) {
                statementCurrency = code; break
            }
            let lower = line.lowercased()
            if lower.contains("currency") || lower.contains("amounts in") {
                if let code = firstKnownCurrencyCode(in: line) { statementCurrency = code; break }
            }
        }

        // Period: an explicit "period … to …" header line wins; otherwise
        // min…max of the transaction dates (CSV behaviour).
        var period = headerPeriod(in: headerLines)
        if period == nil {
            let dates = transactions.map { $0.date }
            period = dates.min().flatMap { lo in dates.max().map { lo...$0 } }
        }

        return ParsedStatement(bankHint: bankHint, accountLast4: accountLast4,
                               statementCurrency: statementCurrency, period: period,
                               transactions: transactions, warnings: warnings)
    }

    // MARK: - Helpers

    /// A money-shaped number: plain digits, grouped triplets, an optional
    /// 2-decimal tail. What this rejects is the load-bearing part: an FX
    /// RATE like "10.397545" (HSBC One prints "FCY Savings GBP 10.397545"
    /// in its portfolio summary) must never be read as an original amount —
    /// its digits-only fallback once became a 10.4-million "purchase".
    static let moneyShapedToken: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?$|^\d+$"#
    )

    /// First whitelisted "XXX 1,234"-style token in a description. The value
    /// is decoded with the document's decimal mode only when it actually has
    /// a 2-digit decimal tail; otherwise separators are grouping (JPY 12,300).
    static func firstForeignAmount(in text: String, commaDecimal: Bool)
    -> (code: String, value: Decimal, range: NSRange)? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in foreignAmount.matches(in: text, range: full) {
            let code = ns.substring(with: match.range(at: 1))
            guard knownCurrencies.contains(code) else { continue }
            let token = ns.substring(with: match.range(at: 2))
            let tokenRange = NSRange(location: 0, length: (token as NSString).length)
            guard moneyShapedToken.firstMatch(in: token, range: tokenRange) != nil else { continue }
            let hasDecimalTail = token.range(of: #"[.,]\d{2}$"#, options: .regularExpression) != nil
            let value: Decimal?
            if hasDecimalTail {
                value = CSVImporter.parseAmount(token, commaDecimal: commaDecimal)
            } else {
                let digits = token.filter { $0.isNumber }
                value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX"))
            }
            guard let value else { continue }
            return (code, value, match.range)
        }
        return nil
    }

    /// First known ISO code appearing as a standalone uppercase triple.
    static func firstKnownCurrencyCode(in line: String) -> String? {
        let ns = line as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Z]{3}\b"#) else { return nil }
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let code = ns.substring(with: match.range)
            if knownCurrencies.contains(code) { return code }
        }
        return nil
    }

    /// "Statement period 01 Jun 2026 to 30 Jun 2026" → that range. Needs a
    /// period-ish keyword and at least two parseable dates on the same line.
    static func headerPeriod(in headerLines: [String]) -> ClosedRange<Date>? {
        let formats = ["d MMM yyyy", "yyyy-MM-dd", "d/M/yyyy", "d.M.yyyy", "MMM d, yyyy"]
        let formatters: [DateFormatter] = formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = fmt
            return f
        }
        let dateToken = try! NSRegularExpression(
            pattern: #"\d{4}-\d{2}-\d{2}|\d{1,2}([./])\d{1,2}\1\d{4}|\d{1,2}\s+[A-Za-z]{3,9}\.?,?\s+\d{4}|[A-Za-z]{3,9}\.?\s+\d{1,2},\s+\d{4}"#
        )
        for line in headerLines {
            let lower = line.lowercased()
            guard lower.contains("period") || (lower.contains("statement") && lower.contains(" to ")) else { continue }
            let ns = line as NSString
            let tokens = dateToken.matches(in: line, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }
            let dates = tokens.compactMap { token -> Date? in
                for f in formatters {
                    if let d = f.date(from: token) { return d }
                }
                return nil
            }
            if dates.count >= 2, let lo = dates.min(), let hi = dates.max() {
                return lo...hi
            }
        }
        return nil
    }
}
