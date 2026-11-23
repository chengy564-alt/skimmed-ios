import Foundation

/// Bundled reference exchange rates — a single static snapshot, never a live
/// feed. The app uses this table only as an explicitly provisional offline
/// fallback while verified ECB observations are unavailable.
nonisolated public enum RateTable {

    /// HKD value of one unit of the key currency (representative offline
    /// snapshot, not a live quote). `"HKD": 1` is the identity entry so composition
    /// through HKD works uniformly for any pair, including HKD itself.
    public static let toHKD: [String: Decimal] = [
        "HKD": 1,
        "USD": 7.80,
        "EUR": 8.45,
        "GBP": 10.20,
        "JPY": 0.0507,
        "KRW": 0.00565,
        "TWD": 0.245,
        "THB": 0.228,
        "SGD": 5.78,
        "CNY": 1.085,
        "AUD": 5.15,
        "CAD": 5.70,
        "CHF": 8.90,
        "NZD": 4.70,
        "INR": 0.094,
        "IDR": 0.00049,
        "MYR": 1.75,
        "PHP": 0.140,
        "VND": 0.00032,
        "AED": 2.12,
        "SAR": 2.08,
        "ZAR": 0.43,
        "MXN": 0.40,
        "BRL": 1.40,
        "SEK": 0.75,
        "NOK": 0.72,
        "DKK": 1.13,
        "PLN": 1.98,
    ]

    /// Composed rate `from` -> `to`, always routed via HKD (one unit of
    /// `from`, expressed in `to`). Returns nil when either currency isn't in
    /// the bundled table — callers must treat that as "can't compute", never
    /// substitute a guessed rate.
    public static func rate(from: String, to: String) -> Decimal? {
        guard let fromHKD = toHKD[from], let toHKDRate = toHKD[to], toHKDRate != 0 else { return nil }
        return fromHKD / toHKDRate
    }

    /// Explicitly provisional fallback for offline imports. Unlike an ECB
    /// quote, this carries no claim of date-specific verification.
    public static func fallbackQuote(for request: HistoricalRateRequest) -> HistoricalRateQuote? {
        guard let rate = rate(from: request.from, to: request.to) else { return nil }
        return HistoricalRateQuote(
            request: request,
            observationDay: request.day,
            rate: rate,
            source: .bundledFallback,
            status: .provisional
        )
    }
}

/// Best-effort currency-region hint used only where the UI explicitly labels
/// it as a hint. It is never merchant-country evidence or financial input.
/// Deliberately approximate because one currency can span many countries.
nonisolated public enum CurrencyCountry {
    private static let table: [String: String] = [
        "HKD": "HK", "THB": "TH", "JPY": "JP", "KRW": "KR", "TWD": "TW",
        "SGD": "SG", "USD": "US", "GBP": "GB", "EUR": "NL", "CNY": "CN",
        "AUD": "AU", "CAD": "CA", "CHF": "CH", "NZD": "NZ", "INR": "IN",
        "IDR": "ID", "MYR": "MY", "PHP": "PH", "VND": "VN", "AED": "AE",
        "SAR": "SA", "ZAR": "ZA", "MXN": "MX", "BRL": "BR", "SEK": "SE",
        "NOK": "NO", "DKK": "DK", "PLN": "PL",
    ]

    public static func country(for currency: String) -> String? {
        table[currency]
    }

    /// Currency for a destination explicitly selected by the user. This is
    /// not merchant-country inference: the country is the input, not a claim
    /// derived from a transaction currency.
    public static func currency(forCountry country: String) -> String? {
        let region = country.uppercased()
        guard region.count == 2,
              region.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return Locale(identifier: "en_\(region)").currency?.identifier
    }
}
