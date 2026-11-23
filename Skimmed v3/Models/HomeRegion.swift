import Foundation

/// Curated home-region options for the editable "Home region" setting
/// (Profile's travel-profile card + Settings → Region & currency share this
/// single list so the two surfaces can never drift). Each option pairs an
/// ISO 3166 country code with its ISO 4217 currency; both are written to
/// `@AppStorage("profile.homeCountry")` / `"profile.homeCurrency")` when
/// selected. An "Other" entry outside this list (from the custom
/// country/currency pickers) is still valid — `name(forCountry:)` falls back
/// to the raw code for anything not curated here.
enum HomeRegion {
    struct Option: Identifiable {
        var id: String { country }
        let country: String
        let currency: String
        let name: String
    }

    /// The default before a user has ever changed it (same role `RateProvider
    /// .defaultHomeCurrency` plays for the currency half of the pair). US-first:
    /// most customers are directed at the US market.
    static let defaultCountry = "US"

    static let options: [Option] = [
        Option(country: "US", currency: "USD", name: "United States"),
        Option(country: "HK", currency: "HKD", name: "Hong Kong"),
        Option(country: "GB", currency: "GBP", name: "United Kingdom"),
        Option(country: "SG", currency: "SGD", name: "Singapore"),
        Option(country: "JP", currency: "JPY", name: "Japan"),
        Option(country: "AU", currency: "AUD", name: "Australia"),
        Option(country: "EU", currency: "EUR", name: "Eurozone"),
        Option(country: "CA", currency: "CAD", name: "Canada"),
    ]

    /// Display name for a country code — falls back to the code itself so a
    /// custom "Other" pick still renders something sane.
    static func name(forCountry country: String) -> String {
        options.first(where: { $0.country == country })?.name ?? country
    }
}
