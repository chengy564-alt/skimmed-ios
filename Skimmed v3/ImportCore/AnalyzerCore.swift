import Foundation

/// Confidence tier for one analyzed row. Matches the data-model doc's
/// three-way split:
///  - `exact`: both the settled leg (amount+currency) and a foreign original
///    leg (originalAmount+originalCurrency) are present in the statement.
///  - `estimated`: the local/original amount is a reverse-estimate rather
///    than a bank-stated figure — always used for DCC-suspected rows (see
///    `AnalyzerCore.classify`), matching `LocalAmountSource.estimated` /
///    `MarkupConfidence.estimated` in the app's data model.
///  - `unableToCalculate`: insufficient data to compute a markup at all
///    (foreign currency evidence with no original amount to compare against).
///    Excluded from loss sums, but the row is still kept and listed.
public enum RowConfidence: String, Codable, Equatable {
    case exact
    case estimated
    case unableToCalculate
}

/// The dated quotes resolved for one statement row. The reference quote
/// compares the original merchant currency with home currency; the optional
/// second quote converts a foreign-denominated settled leg into home currency.
public struct TransactionRateContext: Equatable {
    public let reference: HistoricalRateQuote?
    public let settledToHome: HistoricalRateQuote?

    public init(reference: HistoricalRateQuote?, settledToHome: HistoricalRateQuote?) {
        self.reference = reference
        self.settledToHome = settledToHome
    }
}

/// One classified statement row — pure value type, no app types.
public struct RowAnalysis: Equatable {
    public let tx: ParsedTransaction
    public let fingerprint: String
    public let isForeign: Bool
    public let isDccSuspected: Bool
    public let billedAmount: Decimal
    public let billedCurrency: String
    public let homeCurrencyAmount: Decimal
    public let referenceRate: Decimal?
    public let effectiveRate: Decimal?
    /// The TRUE signed markup (settled home value minus original x reference
    /// rate). Deliberately NOT floored at zero when negative — a negative
    /// markup means the cardholder got a BETTER-than-reference rate, which is
    /// real information worth keeping. Callers exclude negative values from
    /// "flagged" counts and positive-only sums, but never clamp/discard them.
    public let markupAmount: Decimal?
    public let confidence: RowConfidence
    public let referenceRateQuote: HistoricalRateQuote?
    public let settledToHomeQuote: HistoricalRateQuote?

    public init(
        tx: ParsedTransaction,
        fingerprint: String,
        isForeign: Bool,
        isDccSuspected: Bool,
        billedAmount: Decimal,
        billedCurrency: String,
        homeCurrencyAmount: Decimal,
        referenceRate: Decimal?,
        effectiveRate: Decimal?,
        markupAmount: Decimal?,
        confidence: RowConfidence,
        referenceRateQuote: HistoricalRateQuote? = nil,
        settledToHomeQuote: HistoricalRateQuote? = nil
    ) {
        self.tx = tx
        self.fingerprint = fingerprint
        self.isForeign = isForeign
        self.isDccSuspected = isDccSuspected
        self.billedAmount = billedAmount
        self.billedCurrency = billedCurrency
        self.homeCurrencyAmount = homeCurrencyAmount
        self.referenceRate = referenceRate
        self.effectiveRate = effectiveRate
        self.markupAmount = markupAmount
        self.confidence = confidence
        self.referenceRateQuote = referenceRateQuote
        self.settledToHomeQuote = settledToHomeQuote
    }
}

public enum AnalyzerCore {

    /// Classifies every non-duplicate row in `transactions`. Dedup is keyed
    /// on `Fingerprint.make(cardID:tx:)` against `existingFingerprints`
    /// (B1's fingerprint, cardID = the app's ImportedCard UUID string, per
    /// B1's note to downstream tasks).
    public static func analyze(
        transactions: [ParsedTransaction],
        cardID: String,
        homeCurrency: String,
        existingFingerprints: Set<String>,
        rateContexts: [String: TransactionRateContext] = [:]
    ) -> (rows: [RowAnalysis], duplicatesSkipped: Int) {
        var rows: [RowAnalysis] = []
        rows.reserveCapacity(transactions.count)
        var duplicates = 0
        for tx in transactions {
            let fingerprint = Fingerprint.make(cardID: cardID, tx: tx)
            if existingFingerprints.contains(fingerprint) {
                duplicates += 1
                continue
            }
            rows.append(classify(
                tx: tx,
                fingerprint: fingerprint,
                homeCurrency: homeCurrency,
                rateContext: rateContexts[fingerprint]
            ))
        }
        return (rows, duplicates)
    }

    /// Foreign / DCC / markup classification for a single row.
    ///
    /// Foreign detection is currency-evidence-only (never guessed from
    /// description text): a row is foreign when either the settled currency
    /// differs from `homeCurrency`, or a foreign `originalCurrency` is present.
    ///
    /// **DCC decision (documented, deliberately never guessed):** v1
    /// statement import never sets `isDccSuspected`. The app's DCC signature
    /// (`Types.swift`: merchant country != home country AND billed currency
    /// == home currency) needs a *merchant country*, which `ParsedTransaction`
    /// does not carry — CSV/PDF statements give currency codes, not merchant
    /// geography. We deliberately do NOT reinterpret "settled in home
    /// currency + a foreign original amount also printed" as DCC: that shape
    /// is exactly what transparent banks print for perfectly normal FX (see
    /// the reference mock dataset's Hawker Chan / SGD row — original+settled
    /// both present, not DCC), so treating it as DCC would flag good
    /// transactions as bad ones. Guessing DCC from merchant-name text was
    /// explicitly ruled out by the plan as fabrication. So: no reliable,
    /// honest signal exists from statement data alone -> always `false` for
    /// v1, per the plan's documented fallback option. A later task could add
    /// this back if a real merchant-country source becomes available.
    ///
    /// Confidence, per the plan (input-completeness decides the tier):
    ///  - `exact`: both legs (settled amount+currency AND original
    ///    amount+currency) are on the statement, and the settled currency is
    ///    already home currency — a clean effective-rate computation with no
    ///    rate-table involvement beyond the single reference comparison point.
    ///  - `estimated`: rate-derived — either both legs are present but the
    ///    settled leg itself needed our bundled table to become a
    ///    home-currency figure first (rare: foreign-currency-denominated
    ///    statements), or currency data was incomplete but our bundled table
    ///    could still fill a specific gap.
    ///  - `unableToCalculate`: no original amount to compare the settled
    ///    figure against at all (nothing to reverse-engineer a markup from),
    ///    or the currency isn't in our bundled reference table. Excluded from
    ///    loss sums, but the row is kept and listed, never dropped.
    static func classify(
        tx: ParsedTransaction,
        fingerprint: String,
        homeCurrency: String,
        rateContext: TransactionRateContext? = nil
    ) -> RowAnalysis {
        let settledCurrency = tx.currency ?? homeCurrency
        let hasOriginal = tx.originalAmount != nil && tx.originalCurrency != nil
        let originalIsForeign = hasOriginal && tx.originalCurrency != homeCurrency
        let settledIsForeign = settledCurrency != homeCurrency
        let isForeign = originalIsForeign || settledIsForeign

        // Domestic: no foreign evidence anywhere on the row.
        if !isForeign {
            return RowAnalysis(
                tx: tx, fingerprint: fingerprint, isForeign: false, isDccSuspected: false,
                billedAmount: tx.amount, billedCurrency: settledCurrency,
                homeCurrencyAmount: tx.amount, referenceRate: nil, effectiveRate: nil,
                markupAmount: nil, confidence: .exact
            )
        }

        if hasOriginal {
            let originalCurrency = tx.originalCurrency!
            let originalAmount = tx.originalAmount!
            let referenceRequest = HistoricalRateRequest(
                from: originalCurrency,
                to: homeCurrency,
                day: dayString(for: tx.date)
            )
            let referenceQuote = rateContext == nil
                ? RateTable.fallbackQuote(for: referenceRequest)
                : rateContext?.reference
            let referenceRate = referenceQuote?.rate
            var homeAmount = tx.amount
            var neededRateConversion = false
            var conversionFailed = false
            var settledToHomeQuote: HistoricalRateQuote?
            if settledCurrency != homeCurrency {
                // The settled leg itself isn't home currency (e.g. a foreign-currency wallet
                // card) — converting it needs our bundled table, so this figure is rate-derived,
                // not statement-stated -> demotes the row to `estimated`. When the settled
                // currency is off-table the figure can't be converted at all; comparing the
                // raw foreign number to a home-currency reference would fabricate a markup,
                // so the row collapses to `unableToCalculate` instead.
                neededRateConversion = true
                let settledRequest = HistoricalRateRequest(
                    from: settledCurrency,
                    to: homeCurrency,
                    day: dayString(for: tx.date)
                )
                settledToHomeQuote = rateContext == nil
                    ? RateTable.fallbackQuote(for: settledRequest)
                    : rateContext?.settledToHome
                if let settledToHomeQuote {
                    homeAmount = tx.amount * settledToHomeQuote.rate
                } else {
                    conversionFailed = true
                }
            }
            // Debits and refunds can both preserve valid two-leg FX evidence;
            // only a zero denominator makes an effective rate impossible.
            let invalidOriginalAmount = originalAmount == 0
            let effectiveRate: Decimal? = (!invalidOriginalAmount && !conversionFailed)
                ? homeAmount / originalAmount : nil
            let markup = referenceRate.map { homeAmount - originalAmount * $0 }
            // Plausibility guard: real card FX markups live within a few
            // percent of the reference rate. An implied rate beyond ±50% of
            // reference means the row was misparsed (an account/reference
            // number captured as an amount, mixed-up columns, …) — claiming
            // a "markup" on it would fabricate enormous nonsense totals, so
            // the row collapses to unableToCalculate instead.
            var implausibleRate = false
            if let referenceRate, let effectiveRate, referenceRate != 0 {
                let ratio = effectiveRate / referenceRate
                if ratio < Decimal(0.5) || ratio > Decimal(2.0) { implausibleRate = true }
            }
            let confidence: RowConfidence
            if invalidOriginalAmount
                || referenceRate == nil
                || (neededRateConversion && effectiveRate == nil)
                || implausibleRate {
                confidence = .unableToCalculate
            } else if neededRateConversion {
                confidence = .estimated
            } else {
                confidence = .exact
            }
            return RowAnalysis(
                tx: tx, fingerprint: fingerprint, isForeign: true, isDccSuspected: false,
                billedAmount: originalAmount, billedCurrency: originalCurrency,
                homeCurrencyAmount: homeAmount, referenceRate: referenceRate, effectiveRate: effectiveRate,
                markupAmount: confidence == .unableToCalculate ? nil : markup, confidence: confidence,
                referenceRateQuote: referenceQuote, settledToHomeQuote: settledToHomeQuote
            )
        } else {
            // Foreign evidence only from the settled leg, no original amount to compare
            // against -> honestly unableToCalculate. We never fabricate a markup by assuming
            // the reference rate was actually charged.
            let referenceRequest = HistoricalRateRequest(
                from: settledCurrency,
                to: homeCurrency,
                day: dayString(for: tx.date)
            )
            let referenceQuote = rateContext == nil
                ? RateTable.fallbackQuote(for: referenceRequest)
                : rateContext?.reference
            let referenceRate = referenceQuote?.rate
            let homeAmount = referenceRate.map { tx.amount * $0 } ?? tx.amount
            return RowAnalysis(
                tx: tx, fingerprint: fingerprint, isForeign: true, isDccSuspected: false,
                billedAmount: tx.amount, billedCurrency: settledCurrency,
                homeCurrencyAmount: homeAmount, referenceRate: referenceRate, effectiveRate: nil,
                markupAmount: nil, confidence: .unableToCalculate,
                referenceRateQuote: referenceQuote
            )
        }
    }

    public static func dayString(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
