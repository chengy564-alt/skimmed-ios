import Foundation

/// Thin app-facing wrapper over `RateTable` (ImportCore's pure, unit-tested
/// bundled reference-rate math). Deliberately pure — it does NOT read
/// `@AppStorage` itself; callers (views/AppStore) read
/// `@AppStorage("profile.homeCurrency")` (default `"HKD"`, see
/// `RateProvider.defaultHomeCurrency`) and pass the resolved home currency
/// in. Keeping this type storage-free makes it trivially testable and
/// reusable from both the app target and ImportCore's test target's
/// equivalents.
enum RateProvider {
    /// Default home currency when the user hasn't set one, matching
    /// `RegionConfig.hkd`'s `homeCurrency` used by demo mode.
    static let defaultHomeCurrency = "USD"

    /// Composed reference rate `from` -> `to`, routed via HKD. `nil` when
    /// either currency isn't in the bundled snapshot table.
    static func rate(from: String, to: String) -> Decimal? {
        RateTable.rate(from: from, to: to)
    }
}
