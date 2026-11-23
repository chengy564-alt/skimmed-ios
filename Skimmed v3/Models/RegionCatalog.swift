import Foundation

/// Region launch configuration — per-market copy, pricing anchors, bank
/// grids, and destination chips used by onboarding and the reveal evidence
/// screen. (Formerly `MockData`; the seeded demo dataset that used to live
/// here was removed before the first App Store release.)
enum RegionCatalog {

    static let regionConfigs: [RegionId: RegionConfig] = [
        .hkd: RegionConfig(
            id: .hkd,
            homeCurrency: "HKD",
            homeCountry: "HK",
            aggregator: .finverse,
            evidenceCitationText: "Banks in Hong Kong typically add **1.95%–3.5%** on top of the real exchange rate — the HKMA requires them to disclose it, but only in the fine print. Dynamic Currency Conversion ('pay in HKD?') adds another **4–8%** per Visa's own published data. We compare foreign charges with enough statement detail against a date-matched ECB reference rate; offline estimates are labelled and update automatically.",
            priceAnnual: 248,
            priceMonthly: 38,
            floorThreshold: 400,
            // Verified against Finverse's published HK Data API coverage
            // (finverse.com/bank-data-api): HSBC, Hang Seng, Standard Chartered,
            // Bank of China, BEA, DBS. Citi/Mox/ZA/livi/WeLab are NOT supported.
            bankGrid: ["HSBC", "Hang Seng", "SC", "BOC", "BEA", "DBS"],
            destinationChips: ["Japan", "Thailand", "Taiwan", "Singapore", "Korea", "Mainland", "Europe/US", "Other"]
        ),
        .usd: RegionConfig(
            id: .usd,
            homeCurrency: "USD",
            homeCountry: "US",
            aggregator: .plaid,
            evidenceCitationText: "Most US credit cards charge a **foreign transaction fee of up to 3%** — disclosed in the Schumer box of your card agreement, as required under Regulation Z (Truth in Lending), then never totaled anywhere. Dynamic Currency Conversion ('pay in USD?') adds another **4–8%** per Visa's own published data. We compare foreign charges with enough statement detail against a date-matched ECB reference rate; offline estimates are labelled and update automatically.",
            priceAnnual: 34.99,
            priceMonthly: 4.99,
            floorThreshold: 50,
            bankGrid: ["Chase", "Bank of America", "Wells Fargo", "Citi", "Capital One", "Amex", "Discover", "US Bank", "Charles Schwab", "Chime"],
            destinationChips: ["Mexico", "Canada", "Europe", "UK", "Caribbean", "Japan", "Other"]
        ),
        .gbp: RegionConfig(
            id: .gbp,
            homeCurrency: "GBP",
            homeCountry: "GB",
            aggregator: .truelayer,
            evidenceCitationText: "Most UK cards add a **non-sterling transaction fee of ~2.75%–2.99%**. Under the Cross-Border Payments Regulation (retained EU rules, in force since April 2020), your issuer must publish its total currency-conversion markup against the ECB reference rate — which is how we know exactly what they charge. Dynamic Currency Conversion ('pay in GBP?') adds another **4–8%** per Visa's own published data. We compare foreign charges with enough statement detail against a date-matched ECB reference rate; offline estimates are labelled and update automatically.",
            priceAnnual: 27.99,
            priceMonthly: 3.99,
            floorThreshold: 40,
            bankGrid: ["Barclays/Barclaycard", "HSBC UK", "Lloyds", "Halifax", "NatWest", "Santander", "Nationwide", "Monzo", "Starling", "Amex UK"],
            destinationChips: ["Spain", "France", "Italy", "Greece", "Portugal", "US", "Other"]
        ),
    ]

    /// Resolves from the user's chosen home country (USD fallback).
    static var activeRegion: RegionConfig { regionConfigs[RegionId.active]! }
}

extension RegionId {
    /// The copy/config region for the stored home country: HK and GB have
    /// their own sets; every other market falls back to the USD set (its
    /// currency still comes from `profile.homeCurrency`, not from here).
    static var active: RegionId {
        switch UserDefaults.standard.string(forKey: "profile.homeCountry") ?? HomeRegion.defaultCountry {
        case "HK": return .hkd
        case "GB": return .gbp
        default: return .usd
        }
    }
}
