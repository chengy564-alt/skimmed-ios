import Foundation

/// Derived aggregations + formatting helpers (ported from `lib/derive.ts`).
/// Everything on Reveal/Home is computed from the imported data, never
/// hardcoded in views.
enum Derive {

    static func round2(_ n: Double) -> Double {
        (n * 100).rounded() / 100
    }

    private static let currencySymbols: [String: String] = [
        "HKD": "HK$", "USD": "$", "GBP": "£", "SGD": "S$", "JPY": "¥",
        "AUD": "A$", "EUR": "€", "CAD": "C$", "NZD": "NZ$", "TWD": "NT$",
        "KRW": "₩", "CNY": "¥", "AED": "AED ", "CHF": "CHF ",
    ]

    /// The user's home-currency ISO code (what every loss is measured in).
    static var homeCurrencyCode: String {
        UserDefaults.standard.string(forKey: "profile.homeCurrency") ?? RateProvider.defaultHomeCurrency
    }

    /// The display symbol for the home currency — for count-up prefixes and
    /// copy that can't go through `fmtMoney`.
    static var moneySymbol: String {
        currencySymbols[homeCurrencyCode] ?? (homeCurrencyCode + " ")
    }

    /// Formats an amount in the user's home currency (the currency every
    /// loss is measured in). Falls back to "CODE " for uncurated currencies.
    static func fmtMoney(_ n: Double, decimals: Int = 0) -> String {
        let symbol = moneySymbol
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        let body = formatter.string(from: NSNumber(value: n)) ?? String(n)
        return symbol + body
    }

    static func fmtPct(_ n: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", n) + "%"
    }

    /// Flag emoji for any ISO 3166 alpha-2 code, composed from Unicode
    /// regional-indicator symbols — covers every country, not a short list.
    /// "EU" resolves to the European Union flag; anything that isn't two
    /// ASCII letters (e.g. "??") falls back to the white flag.
    static func flag(_ countryCode: String) -> String {
        let code = countryCode.uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "🏳️" }
        let base: UInt32 = 0x1F1E6 // regional indicator "A"
        var scalarView = String.UnicodeScalarView()
        for v in code.unicodeScalars {
            guard let scalar = Unicode.Scalar(base + (v.value - 65)) else { return "🏳️" }
            scalarView.append(scalar)
        }
        return String(scalarView)
    }

    private static let monthShort = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// "2025-06-14" -> "14 Jun 25"
    static func fmtDate(_ iso: String) -> String {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return iso }
        return "\(parts[2]) \(monthShort[parts[1] - 1]) \(String(parts[0]).suffix(2))"
    }

    /// "2026-06" -> "Jun"
    static func monthLabel(_ ym: String) -> String {
        let parts = ym.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2, (1...12).contains(parts[1]) else { return ym }
        return monthShort[parts[1] - 1]
    }

    struct MonthLoss: Identifiable {
        let month: String // "YYYY-MM"
        let total: Double
        var id: String { month }
    }

    /// Loss by calendar month across the whole scanned window (zero-filled).
    static func lossByMonth(_ txs: [Transaction]) -> [MonthLoss] {
        var sums: [String: Double] = [:]
        for t in txs {
            let ym = String(t.txDate.prefix(7))
            sums[ym, default: 0] += max(0, t.markupAmount)
        }
        let months = sums.keys.sorted()
        guard let first = months.first, let last = months.last else { return [] }
        let firstParts = first.split(separator: "-").compactMap { Int($0) }
        var y = firstParts[0]
        var m = firstParts[1]
        var out: [MonthLoss] = []
        while true {
            let ym = String(format: "%04d-%02d", y, m)
            out.append(MonthLoss(month: ym, total: round2(sums[ym] ?? 0)))
            if ym == last { break }
            m += 1
            if m > 12 {
                m = 1
                y += 1
            }
        }
        return out
    }

    static func totalMarkup(_ txs: [Transaction]) -> Double {
        round2(txs.reduce(0) { $0 + max(0, $1.markupAmount) })
    }

    static func markupForAccount(_ txs: [Transaction], accountId: String) -> Double {
        totalMarkup(txs.filter { $0.linkedAccountId == accountId })
    }

    /// Whole days between two ISO "yyyy-MM-dd" dates (endISO - startISO).
    static func daysBetween(_ startISO: String, _ endISO: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let a = formatter.date(from: startISO), let b = formatter.date(from: endISO) else {
            return 0
        }
        return Int(b.timeIntervalSince(a) / 86_400)
    }

    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Today's date as an ISO "yyyy-MM-dd" string — real mode's stand-in for
    /// demo's pinned `referenceDate`.
    static var isoToday: String { isoDayFormatter.string(from: Date()) }

    /// A `Date` as an ISO "yyyy-MM-dd" string.
    static func isoDate(_ date: Date) -> String { isoDayFormatter.string(from: date) }

    // MARK: - Display-only geography helpers (B6)
    //
    // These are presentation heuristics only — never used for financial
    // math (that stays on ImportCore's `CurrencyCountry`/`RateTable`).

    private static let cityNames: [String: String] = [
        "SG": "Singapore", "KR": "Seoul", "JP": "Tokyo", "TW": "Taipei",
        "TH": "Bangkok", "HK": "Hong Kong", "US": "the US", "GB": "the UK",
        "NL": "the Netherlands", "CN": "China",
    ]

    /// Best-effort city label for a destination country code, e.g. for trip
    /// hero cards. Falls back to the country code itself when unknown.
    static func cityName(_ countryCode: String) -> String {
        cityNames[countryCode] ?? countryCode
    }

    private static let countryNames: [String: String] = [
        "TH": "Thailand", "JP": "Japan", "KR": "Korea", "TW": "Taiwan",
        "SG": "Singapore", "US": "United States", "GB": "United Kingdom",
        "NL": "Netherlands", "CN": "Mainland China", "HK": "Hong Kong",
        "AU": "Australia", "NZ": "New Zealand", "CA": "Canada",
        "DE": "Germany", "FR": "France", "ES": "Spain", "IT": "Italy",
        "AE": "UAE", "EU": "Eurozone", "INTL": "International",
    ]

    /// Best-effort country display name — search chips, destination prep
    /// cards. Falls back to the country code itself when unknown.
    static func countryName(_ countryCode: String) -> String {
        countryNames[countryCode] ?? countryCode
    }

    /// Spoken name for a currency, for the DCC refusal script ("In baht,
    /// please"). Falls back to the ISO code, which still reads fine.
    static func currencySpokenName(_ currency: String) -> String {
        let names: [String: String] = [
            "THB": "baht", "JPY": "yen", "KRW": "won",
            "TWD": "Taiwan dollars", "SGD": "Singapore dollars",
            "USD": "US dollars", "EUR": "euros", "GBP": "pounds",
            "HKD": "Hong Kong dollars", "CNY": "yuan",
            "AUD": "Australian dollars", "CAD": "Canadian dollars",
        ]
        return names[currency] ?? currency
    }

    /// Onboarding Q2 destination-chip label -> (country code, likely
    /// currency) — display-only heuristic used to build the Trips
    /// pre-history prep cards and the waitlist country prefill. Covers every
    /// `RegionConfig.destinationChips` value across all three launch regions.
    static func destinationInfo(_ label: String) -> (country: String, currency: String)? {
        // New storage is an ISO alpha-2 code; resolve its currency directly.
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 2, trimmed.uppercased().allSatisfy({ $0.isASCII && $0.isLetter }) {
            let code = trimmed.uppercased()
            if let currency = CurrencyCountry.currency(forCountry: code) {
                return (code, currency)
            }
        }
        // Legacy chip labels ("Japan", "Europe/US") stay resolvable.
        let table: [String: (String, String)] = [
            "Japan": ("JP", "JPY"),
            "Thailand": ("TH", "THB"),
            "Taiwan": ("TW", "TWD"),
            "Singapore": ("SG", "SGD"),
            "Korea": ("KR", "KRW"),
            "Mainland": ("CN", "CNY"),
            "Europe/US": ("US", "USD"),
            "Mexico": ("MX", "MXN"),
            "Canada": ("CA", "CAD"),
            "Europe": ("NL", "EUR"),
            "UK": ("GB", "GBP"),
            "Caribbean": ("BS", "USD"),
            "Spain": ("ES", "EUR"),
            "France": ("FR", "EUR"),
            "Italy": ("IT", "EUR"),
            "Greece": ("GR", "EUR"),
            "Portugal": ("PT", "EUR"),
            "US": ("US", "USD"),
        ]
        return table[label]
    }
}
