import Foundation

/// Skimmed — Data Model v1 (Swift mirror)
///
/// These types mirror `fx-fee-finder-data-model.md` (ported from the
/// reference prototype's `lib/types.ts`), trimmed to what the shipping app
/// actually uses. Dates/timestamps are ISO strings; decimals are Doubles.
///
/// NOTE: struct property order is load-bearing — RegionCatalog.swift uses the
/// compiler-generated memberwise initializers, whose argument order follows
/// property declaration order. Don't reorder fields.

// MARK: - region_config

enum RegionId: String, CaseIterable, Hashable {
    case hkd, usd, gbp
}

enum Aggregator: String {
    case finverse, plaid, truelayer
    case statementImport = "statement_import"
}

struct RegionConfig {
    let id: RegionId
    let homeCurrency: String // ISO 4217
    let homeCountry: String // ISO 3166
    let aggregator: Aggregator
    let evidenceCitationText: String // the Screen 4 regulatory paragraph
    let priceAnnual: Double // local-currency price points
    let priceMonthly: Double
    let floorThreshold: Double // below this, Reveal pivots to forward-looking framing
    let bankGrid: [String] // Screen 3b institution list
    let destinationChips: [String] // Screen 3a Q2 options
}

// MARK: - user

enum TripFreqBucket: String, CaseIterable {
    case one = "1"
    case two = "2"
    case three = "3"
    case four = "4"
    case tenPlus = "10+"
    case airports = "airports"

    /// Short glyph shown under each slider detent.
    var displayLabel: String {
        switch self {
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .tenPlus: return "10+"
        case .airports: return "✈️"
        }
    }

    /// Refined one-line description of the selected frequency.
    var caption: String {
        switch self {
        case .one: return "1 trip a year"
        case .two: return "2 trips a year"
        case .three: return "3 trips a year"
        case .four: return "4 trips a year"
        case .tenPlus: return "10+ trips a year"
        case .airports: return "I basically live in airports"
        }
    }

    /// Light travelers — Home shows forward-looking prep framing.
    var isOccasional: Bool { self == .one || self == .two }

    /// Heavy travelers — Home shows live monitoring framing.
    var isFrequent: Bool { self == .tenPlus || self == .airports }
}

// MARK: - linked_account

enum AccountType: String {
    case credit, debit
}

enum AccountStatus: String {
    case active
    case needsReauth = "needs_reauth"
    case revoked
}

struct LinkedAccount: Identifiable {
    let id: String
    let userId: String
    let aggregator: Aggregator // matches region_config at link time
    let aggregatorItemId: String // aggregator's own reference
    let institutionName: String // e.g. "HSBC"
    let displayName: String // e.g. "HSBC Red" — used in Card Ranking copy
    let last4: String
    let accountType: AccountType
    let status: AccountStatus
    let linkedAt: String
}

// MARK: - transaction

enum LocalAmountSource: String {
    case actual // normal FX, aggregator gave local amount
    case estimated // DCC reverse-estimate
}

enum MarkupConfidence: String {
    case exact // real local amount known
    case estimated // DCC reverse-estimate — surfaced in UI as an "estimated" badge
}

struct Transaction: Identifiable {
    let id: String
    let linkedAccountId: String
    let txDate: String
    let merchantName: String
    let merchantCountry: String // verified ISO 3166, or "??" when unknown
    let currencyCountryHint: String? // display-only hint; never financial evidence
    /// Best-effort country for FLAGS/MAP grouping only (never financial
    /// evidence): a planned trip's tagged destination when this row belongs
    /// to one, else the currency hint. `nil` when neither is known.
    let displayCountry: String?
    let billedCurrency: String // what the aggregator reports settled
    let billedAmount: Double
    let isForeign: Bool // supported by the statement's currency legs
    let isDccSuspected: Bool // only when trustworthy statement evidence supports it
    let localCurrencyInferred: String? // from country_currency_map, when isDccSuspected
    let localAmountEstimated: Double? // reverse-estimated only for DCC-suspected rows
    let localAmountSource: LocalAmountSource
    let homeCurrencyAmount: Double // fixed at write time — append-only in v1
    let midMarketRate: Double // rate applied, from fx_rate
    let effectiveRate: Double // rate the bank/DCC actually charged
    let markupAmount: Double // the "loss" for this transaction
    let markupConfidence: MarkupConfidence
    let isMarkupCalculable: Bool // false means the statement did not preserve enough FX evidence
    let revealIncluded: Bool // part of the original scan vs. discovered later
    let referenceRateSource: HistoricalRateSource?
    let calculationStatus: HistoricalCalculationStatus
    let referenceRateDate: String?
}

// MARK: - trip

struct Trip: Identifiable {
    let id: String
    let userId: String
    let destinationCountry: String // primary destination (v1: track primary only)
    let destinationCurrency: String
    let startDate: String
    let endDate: String? // nil while open; auto-closed after 5 quiet days
    let totalMarkupThisTrip: Double // derived from linked transactions
}

// MARK: - reveal_snapshot

struct RevealSnapshot {
    let id: String
    let userId: String
    let periodStart: String // dynamic, reflects actual history pulled (up to ~24mo)
    let periodEnd: String
    let totalLossAmount: Double
    let transactionCount: Int
    let worstOffenderLinkedAccountId: String
    let dccTrapCount: Int
    let isEstimate: Bool // true for the cold-start / skip-linking fallback path
    let yoyComparisonPct: Double? // only computable once 24mo history exists
    let generatedAt: String
}

// MARK: - card_ranking

struct RankedAccount {
    let linkedAccountId: String
    let markupPct: Double
    let confidence: RecommendationConfidence
    let evidenceCount: Int
    let isTiedBest: Bool
}

struct CardRanking {
    let userId: String
    let destinationCurrency: String
    let evidenceTier: RecommendationEvidenceTier
    let rankedAccounts: [RankedAccount]
    let computedAt: String
}

extension RecommendationConfidence {
    var evidenceLabel: String {
        switch self {
        case .strong: "STRONG EVIDENCE"
        case .developing: "DEVELOPING EVIDENCE"
        case .limited: "LIMITED EVIDENCE"
        case .insufficient: "NOT ENOUGH DATA"
        }
    }
}
