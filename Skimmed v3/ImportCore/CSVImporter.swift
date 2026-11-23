import Foundation

/// ImportCore — CSV statement parser
///
/// Whole-file, on-device, pure Foundation. Handles the mess real bank
/// exports throw at us: UTF-8/UTF-16 (BOM or not), `,` `;` `\t` delimiters,
/// RFC-4180 quoting, preamble lines above the header, five date formats with
/// day/month disambiguation by column scan, decimal commas, signed vs
/// debit/credit amounts. Auto-parses only when header synonyms give a
/// confident column mapping — otherwise throws `.needsMapping` so the user
/// maps columns once and we remember it (MappingTemplateStore).
public enum CSVImporter {

    // MARK: - Public entry points

    /// Auto-parse: locates the header row, infers a ColumnMapping from
    /// header synonyms, and parses. Throws `.needsMapping` (with the real
    /// headers + up to 5 sample rows) when the required trio — date,
    /// description, and an amount or debit/credit column — can't be matched
    /// confidently. `filename` is only a bank-hint fallback; content wins.
    public static func parse(data: Data, filename: String) throws -> ParsedStatement {
        let text = try decode(data)
        let delimiter = sniffDelimiter(text)
        let records = tokenize(text, delimiter: delimiter)
        guard !records.isEmpty else { throw ImportError.empty }

        let headerIndex = locateHeaderRow(records.map { $0.cells })
        let headers = records[headerIndex].cells
        let dataRecords = Array(records.suffix(from: headerIndex + 1))
        guard !dataRecords.isEmpty else { throw ImportError.empty }

        guard let mapping = inferMapping(headers: headers) else {
            throw ImportError.needsMapping(
                headers: headers,
                sampleRows: Array(dataRecords.prefix(5).map { $0.cells })
            )
        }
        let preamble = records.prefix(headerIndex).map { $0.raw }
        return try build(records: dataRecords, headers: headers, mapping: mapping,
                         preamble: preamble, filename: filename)
    }

    /// Mapping-driven parse for the manual/template path. The first
    /// non-empty row is always treated as the header row (bank exports that
    /// reach MappingView all have one); data starts on row two.
    public static func parse(data: Data, mapping: ColumnMapping) throws -> ParsedStatement {
        let text = try decode(data)
        let delimiter = sniffDelimiter(text)
        let records = tokenize(text, delimiter: delimiter)
        guard records.count > 1 else { throw ImportError.empty }
        return try build(records: Array(records.dropFirst()), headers: records[0].cells,
                         mapping: mapping, preamble: [], filename: nil)
    }

    /// Header + sample rows for MappingView, without committing to a parse.
    /// Uses the same header-row locator as auto-parse so preamble lines
    /// (account info above the real header) don't leak into the picker.
    public static func headers(data: Data) throws -> (headers: [String], sampleRows: [[String]]) {
        let text = try decode(data)
        let delimiter = sniffDelimiter(text)
        let records = tokenize(text, delimiter: delimiter)
        guard !records.isEmpty else { throw ImportError.empty }
        let headerIndex = locateHeaderRow(records.map { $0.cells })
        let samples = records.suffix(from: min(headerIndex + 1, records.count)).prefix(5)
        return (records[headerIndex].cells, samples.map { $0.cells })
    }

    // MARK: - Encoding

    /// Decode statement bytes to text. Order: BOM-declared UTF-8/UTF-16,
    /// plain UTF-8, BOM-less UTF-16 (NUL-density heuristic), Latin-1 as a
    /// last resort for old European exports. Anything that decodes to
    /// control-character soup is `.unreadable` — better an honest error than
    /// garbage rows.
    static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw ImportError.empty }
        var text: String?
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            text = String(data: data, encoding: .utf16) // BOM tells it the byte order
        }
        if text == nil { text = String(data: data, encoding: .utf8) }
        if text == nil {
            let head = data.prefix(512)
            let nulls = head.filter { $0 == 0 }.count
            if nulls > head.count / 4 {
                text = String(data: data, encoding: .utf16LittleEndian)
                    ?? String(data: data, encoding: .utf16BigEndian)
            }
        }
        if text == nil { text = String(data: data, encoding: .isoLatin1) }
        guard var t = text else { throw ImportError.unreadable }
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }

        let sample = t.unicodeScalars.prefix(512)
        let control = sample.filter { $0.value < 32 && $0 != "\t" && $0 != "\n" && $0 != "\r" }.count
        guard sample.isEmpty || control * 5 < sample.count else { throw ImportError.unreadable }
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
        return t
    }

    // MARK: - Delimiter + tokenizer

    /// Pick the candidate (`,` `;` `\t`) that occurs most outside quotes in
    /// the first ~10 lines. Decimal commas inside a semicolon file lose the
    /// count to the field separators, which is exactly what we want.
    static func sniffDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        var lines = 0
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); continue }
            guard !inQuotes else { continue }
            if ch == "\n" { lines += 1; if lines >= 10 { break } }
            else if counts[ch] != nil { counts[ch]! += 1 }
        }
        // Ties break toward comma — the overwhelmingly common case.
        let order: [Character] = [",", ";", "\t"]
        var best: Character = ","
        var bestCount = counts[","] ?? 0
        for c in order where (counts[c] ?? 0) > bestCount {
            best = c
            bestCount = counts[c]!
        }
        return best
    }

    struct Record {
        let cells: [String]
        let raw: String // verbatim source line(s) for ParsedTransaction.rawLine
    }

    /// RFC-4180-ish state machine: quoted fields may contain the delimiter,
    /// newlines, and doubled quotes. CRLF/LF/CR all end records; fully-empty
    /// rows are dropped (trailing newline, HSBC-style `,,,,,` padding rows).
    static func tokenize(_ text: String, delimiter: Character) -> [Record] {
        var records: [Record] = []
        var cells: [String] = []
        var field = ""
        var raw = ""
        var inQuotes = false

        func endField() {
            cells.append(field.trimmingCharacters(in: .whitespaces))
            field = ""
        }
        func endRecord() {
            endField()
            if !cells.allSatisfy({ $0.isEmpty }) {
                records.append(Record(cells: cells, raw: raw))
            }
            cells = []
            raw = ""
        }

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\""); raw.append("\"\""); i = next
                    } else {
                        inQuotes = false; raw.append(ch)
                    }
                } else {
                    field.append(ch); raw.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true; raw.append(ch)
                case delimiter:
                    endField(); raw.append(ch)
                case "\r":
                    let next = text.index(after: i)
                    if next >= text.endIndex || text[next] != "\n" { endRecord() } // lone CR ends a record; CRLF waits for the LF
                case "\n":
                    endRecord()
                default:
                    field.append(ch); raw.append(ch)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !cells.isEmpty || !raw.isEmpty { endRecord() }
        return records
    }

    // MARK: - Header matching

    enum Field: CaseIterable {
        case date, description, amount, debit, credit, currency
        case originalAmount, originalCurrency, cardLast4
    }

    /// Header synonyms, English + common EU exports (DE/FR/ES/IT/NL).
    /// ORDER IS LOAD-BEARING twice over: fields are claimed top-to-bottom so
    /// "Original Amount" is taken by originalAmount before plain amount's
    /// contains-match can grab it, and terms within a field are tried in
    /// priority order ("transaction date" beats "post date" beats bare "date").
    static let synonyms: [(field: Field, terms: [String])] = [
        (.originalCurrency, ["original currency", "transaction currency", "foreign currency",
                             "orig currency", "source currency"]),
        (.originalAmount, ["original amount", "original transaction amount", "transaction currency amount",
                           "foreign amount", "orig amount", "source amount"]),
        (.cardLast4, ["card number", "card no", "card ending", "last 4", "last four", "card"]),
        (.debit, ["debit amount", "money out", "paid out", "withdrawal", "debit",
                  "soll", "débit", "uscite", "af"]),
        (.credit, ["credit amount", "money in", "paid in", "deposit", "credit",
                   "haben", "crédit", "entrate", "bij"]),
        (.currency, ["billing currency", "currency", "ccy", "währung", "waehrung",
                     "devise", "moneda", "divisa", "valuta"]),
        (.amount, ["transaction amount", "billed amount", "billing amount", "amount",
                   "betrag", "montant", "importe", "importo", "bedrag", "value"]),
        (.date, ["transaction date", "trans date", "posting date", "post date", "value date",
                 "booking date", "date", "buchungstag", "buchungsdatum", "datum", "fecha",
                 "data", "date de l opération", "date opération"]),
        (.description, ["description", "transaction details", "transaction description", "details",
                        "narrative", "merchant", "payee", "memo", "verwendungszweck",
                        "buchungstext", "libellé", "libelle", "concepto", "descrizione",
                        "omschrijving", "reference"]),
    ]

    /// Lowercase, fold punctuation to spaces, collapse runs — so
    /// "Amount (HKD)" and "amount hkd" compare equal.
    static func normalizeHeader(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            out.append(ch.isLetter || ch.isNumber ? ch : " ")
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// Synonym-driven mapping. Two passes — exact matches across every field
    /// first (so "Value Date" is claimed by date before amount's "value"
    /// contains-match sees it), then substring matches. Returns nil unless
    /// the required trio (date + description + some amount column) is
    /// matched: that is the auto-parse confidence gate.
    static func inferMapping(headers: [String]) -> ColumnMapping? {
        let norm = headers.map(normalizeHeader)
        var assigned: [Field: Int] = [:]
        var claimed = Set<Int>()

        for exactPass in [true, false] {
            for (field, terms) in synonyms where assigned[field] == nil {
                outer: for term in terms {
                    let t = normalizeHeader(term)
                    for (i, h) in norm.enumerated() where !claimed.contains(i) && !h.isEmpty {
                        if exactPass ? h == t : h.contains(t) {
                            assigned[field] = i
                            claimed.insert(i)
                            break outer
                        }
                    }
                }
            }
        }

        guard assigned[.date] != nil, assigned[.description] != nil,
              assigned[.amount] != nil || assigned[.debit] != nil || assigned[.credit] != nil
        else { return nil }

        return ColumnMapping(date: assigned[.date], description: assigned[.description],
                             amount: assigned[.amount], debit: assigned[.debit],
                             credit: assigned[.credit], currency: assigned[.currency],
                             originalAmount: assigned[.originalAmount],
                             originalCurrency: assigned[.originalCurrency],
                             cardLast4: assigned[.cardLast4])
    }

    /// First row (within the top 10) with 2+ synonym-matching cells is the
    /// header; everything above is preamble (bank name, "Card ending 1234").
    static func locateHeaderRow(_ rows: [[String]]) -> Int {
        for (i, row) in rows.prefix(10).enumerated() {
            let score = row.filter { cell in
                let h = normalizeHeader(cell)
                guard !h.isEmpty else { return false }
                return synonyms.contains { _, terms in
                    terms.contains { h == normalizeHeader($0) || h.contains(normalizeHeader($0)) }
                }
            }.count
            if score >= 2 { return i }
        }
        return 0
    }

    // MARK: - Dates

    enum DateStyle {
        case iso // yyyy-MM-dd (time suffix ignored)
        case dotDMY // dd.MM.yyyy — dots are unambiguously European day-first
        case slash(dayFirst: Bool) // dd/MM vs MM/dd, resolved by column scan
        case monthName // d MMM yyyy
        case custom(String) // ColumnMapping.dateFormat passthrough
    }

    /// Classify the date column from its first value; slash dates are
    /// disambiguated by scanning the WHOLE column for a component > 12.
    /// Ambiguity with no evidence defaults to day-first (dd/MM) — most of
    /// the world — with a warning so the preview UI can show the assumption.
    static func inferDateStyle(_ values: [String]) -> (DateStyle, warning: String?) {
        let vs = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = vs.first else { return (.iso, nil) }

        func components(_ s: String, _ sep: Character) -> [Int]? {
            let parts = s.split(separator: sep).map { $0.prefix(while: { $0.isNumber }) }
            let nums = parts.compactMap { Int($0) }
            return nums.count == parts.count && nums.count >= 3 ? nums : nil
        }

        if let c = components(first, "-"), c[0] > 31 { return (.iso, nil) }
        if components(first, ".") != nil { return (.dotDMY, nil) }
        if components(first, "/") != nil {
            var sawDayFirstEvidence = false
            var sawMonthFirstEvidence = false
            for v in vs {
                guard let c = components(v, "/"), c.count >= 2 else { continue }
                if c[0] > 12 { sawDayFirstEvidence = true }
                if c[1] > 12 { sawMonthFirstEvidence = true }
            }
            if sawDayFirstEvidence && !sawMonthFirstEvidence { return (.slash(dayFirst: true), nil) }
            if sawMonthFirstEvidence && !sawDayFirstEvidence { return (.slash(dayFirst: false), nil) }
            return (.slash(dayFirst: true),
                    "Dates like \(first) are ambiguous — assumed day/month/year.")
        }
        if first.first?.isNumber == true, first.contains(where: { $0.isLetter }) {
            return (.monthName, nil)
        }
        return (.iso, nil)
    }

    static func makeDateFormatter(_ style: DateStyle) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        switch style {
        case .iso: f.dateFormat = "yyyy-MM-dd"
        case .dotDMY: f.dateFormat = "d.M.yyyy"
        case .slash(let dayFirst): f.dateFormat = dayFirst ? "d/M/yyyy" : "M/d/yyyy"
        case .monthName: f.dateFormat = "d MMM yyyy"
        case .custom(let fmt): f.dateFormat = fmt
        }
        return f
    }

    static func parseDate(_ raw: String, style: DateStyle, formatter: DateFormatter) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if case .iso = style { return formatter.date(from: String(s.prefix(10))) }
        return formatter.date(from: s)
    }

    // MARK: - Amounts

    /// True when any value in the column looks like a European decimal
    /// comma: final comma followed by 1–2 digits, and after any dot (so
    /// "1.234,56" is comma-decimal but "1,234.56" is not). Decided once per
    /// column so "2.500,00" doesn't parse differently from "45,60".
    static func usesCommaDecimal(_ values: [String]) -> Bool {
        for raw in values {
            let s = raw.filter { $0.isNumber || $0 == "," || $0 == "." }
            guard let lastComma = s.lastIndex(of: ",") else { continue }
            if let lastDot = s.lastIndex(of: "."), lastDot > lastComma { continue }
            let tail = s[s.index(after: lastComma)...]
            if (1...2).contains(tail.count), tail.allSatisfy({ $0.isNumber }) { return true }
        }
        return false
    }

    /// Money-string → Decimal. Strips currency symbols/codes and spaces,
    /// honours (parentheses) and trailing CR (credit → negative) / DR /
    /// trailing-minus markers, then applies the column's separator mode.
    static func parseAmount(_ raw: String, commaDecimal: Bool) -> Decimal? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        let upper = s.uppercased()
        if upper.hasSuffix(" CR") || upper == "CR" { negative = true; s = String(s.dropLast(2)) }
        else if upper.hasSuffix(" DR") { s = String(s.dropLast(2)) }

        s = s.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" || $0 == "+" }
        if s.hasSuffix("-") { negative = true; s = String(s.dropLast()) }
        if s.hasPrefix("+") { s = String(s.dropFirst()) }
        if commaDecimal {
            s = s.replacingOccurrences(of: ".", with: "")
            s = s.replacingOccurrences(of: ",", with: ".")
        } else {
            s = s.replacingOccurrences(of: ",", with: "")
        }
        guard !s.isEmpty, s != "-",
              let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return negative ? -d : d
    }

    /// Last run of 4+ digits → its last 4. Survives "XXXX-XXXX-XXXX-1234",
    /// "**** 5678", "Card ending 4321".
    static func extractLast4(_ raw: String) -> String? {
        var runs: [String] = []
        var current = ""
        for ch in raw {
            if ch.isNumber { current.append(ch) }
            else if !current.isEmpty { runs.append(current); current = "" }
        }
        if !current.isEmpty { runs.append(current) }
        guard let last = runs.last(where: { $0.count >= 4 }) else { return nil }
        return String(last.suffix(4))
    }

    // MARK: - Assembly

    /// Shared back-half of both parse entry points: date-style inference,
    /// per-column decimal-comma mode, sign normalization (see
    /// ParsedTransaction's convention), statement-level currency/last4/bank
    /// hint, min…max period, and row-level skip warnings.
    static func build(records: [Record], headers: [String], mapping: ColumnMapping,
                      preamble: [String], filename: String?) throws -> ParsedStatement {
        var warnings: [String] = []

        func cell(_ rec: Record, _ idx: Int?) -> String {
            guard let idx, idx >= 0, idx < rec.cells.count else { return "" }
            return rec.cells[idx]
        }
        func column(_ idx: Int?) -> [String] {
            guard idx != nil else { return [] }
            return records.map { cell($0, idx) }
        }

        let style: DateStyle
        if let fmt = mapping.dateFormat {
            style = .custom(fmt)
        } else {
            let (s, warning) = inferDateStyle(column(mapping.date))
            style = s
            if let warning { warnings.append(warning) }
        }
        let dateFormatter = makeDateFormatter(style)

        let commaDecimal = usesCommaDecimal(
            column(mapping.amount) + column(mapping.debit) + column(mapping.credit) + column(mapping.originalAmount)
        )

        // Signed-column convention: if the file uses negatives at all, the
        // bank means money-out-negative — flip so spend is positive. An
        // all-positive amount column is already spend-positive.
        var flipSigned = false
        if mapping.amount != nil {
            let parsed = column(mapping.amount).compactMap { parseAmount($0, commaDecimal: commaDecimal) }
            flipSigned = parsed.contains { $0 < 0 }
        }

        func isoCurrency(_ raw: String) -> String? {
            let c = raw.trimmingCharacters(in: .whitespaces).uppercased()
            return (c.count == 3 && c.allSatisfy { $0.isLetter }) ? c : nil
        }

        var transactions: [ParsedTransaction] = []
        for (n, rec) in records.enumerated() {
            let dateRaw = cell(rec, mapping.date)
            guard let date = parseDate(dateRaw, style: style, formatter: dateFormatter) else {
                warnings.append("Skipped row \(n + 1): unrecognised date \"\(dateRaw)\".")
                continue
            }
            var amount: Decimal?
            if mapping.amount != nil, let a = parseAmount(cell(rec, mapping.amount), commaDecimal: commaDecimal) {
                amount = flipSigned ? -a : a
            }
            if amount == nil {
                if let d = parseAmount(cell(rec, mapping.debit), commaDecimal: commaDecimal) {
                    amount = abs(d)
                } else if let c = parseAmount(cell(rec, mapping.credit), commaDecimal: commaDecimal) {
                    amount = -abs(c)
                }
            }
            guard let amount else {
                warnings.append("Skipped row \(n + 1): no readable amount.")
                continue
            }
            // originalAmount inherits the normalized sign of `amount`.
            let original = parseAmount(cell(rec, mapping.originalAmount), commaDecimal: commaDecimal)
                .map { amount < 0 ? -abs($0) : abs($0) }

            transactions.append(ParsedTransaction(
                date: date,
                description: cell(rec, mapping.description).trimmingCharacters(in: .whitespaces),
                amount: amount,
                currency: isoCurrency(cell(rec, mapping.currency)),
                originalAmount: original,
                originalCurrency: original == nil ? nil : isoCurrency(cell(rec, mapping.originalCurrency)),
                cardLast4: extractLast4(cell(rec, mapping.cardLast4)),
                rawLine: rec.raw
            ))
        }
        guard !transactions.isEmpty else { throw ImportError.empty }

        if mapping.originalAmount != nil, mapping.originalCurrency == nil,
           transactions.contains(where: { $0.originalAmount != nil }) {
            warnings.append("Original amounts found without an original-currency column — currency left blank.")
        }

        // Statement currency: uniform per-row value, else "Amount (XXX)" header.
        var statementCurrency: String?
        let rowCurrencies = Set(transactions.compactMap { $0.currency })
        if rowCurrencies.count == 1 {
            statementCurrency = rowCurrencies.first
        } else if rowCurrencies.isEmpty, let aIdx = mapping.amount, aIdx < headers.count {
            statementCurrency = currencyCode(inHeader: headers[aIdx])
        }

        // Account last4: uniform card column, else "ending/card/account …1234" preamble text.
        let rowLast4 = Set(transactions.compactMap { $0.cardLast4 })
        var accountLast4 = rowLast4.count == 1 ? rowLast4.first : nil
        if accountLast4 == nil {
            for line in preamble {
                let lower = line.lowercased()
                if lower.contains("ending") || lower.contains("card") || lower.contains("account"),
                   let l4 = extractLast4(line) {
                    accountLast4 = l4
                    break
                }
            }
        }

        // Bank hint: file body (preamble) beats filename.
        var bankHint: String?
        for line in preamble {
            if let name = BankDetector.bankName(in: line) { bankHint = name; break }
        }
        if bankHint == nil, let filename { bankHint = BankDetector.bankName(in: filename) }

        let dates = transactions.map { $0.date }
        let period: ClosedRange<Date>? = dates.min().flatMap { lo in dates.max().map { lo...$0 } }

        return ParsedStatement(bankHint: bankHint, accountLast4: accountLast4,
                               statementCurrency: statementCurrency, period: period,
                               transactions: transactions, warnings: warnings)
    }

    /// "Amount (HKD)" → "HKD". Only trusts an explicit parenthesised code.
    static func currencyCode(inHeader header: String) -> String? {
        guard let open = header.lastIndex(of: "("),
              let close = header[open...].firstIndex(of: ")") else { return nil }
        let code = header[header.index(after: open)..<close].uppercased()
        return (code.count == 3 && code.allSatisfy { $0.isLetter }) ? String(code) : nil
    }
}
