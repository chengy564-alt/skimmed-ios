import Foundation

/// App-facing wrapper over `AnalyzerCore` (ImportCore's pure, unit-tested
/// classification logic). Adapts `ParsedStatement`/`ParsedTransaction` to the
/// persisted `ImportedTransaction` shape and folds per-row results into an
/// `AnalysisResult` summary.
enum Analyzer {

    /// - Parameters:
    ///   - statement: the parsed statement (B1/B2 output).
    ///   - card: the matched/created `ImportedCard` this statement belongs to
    ///     — its `id` is the `Fingerprint` cardID (per B1's note: dedup keys
    ///     on the ImportedCard UUID).
    ///   - homeCountry: reserved for future merchant-country-aware framing;
    ///     not required for the currency-evidence-only foreign/DCC math
    ///     below (see `AnalyzerCore.classify`'s doc comment).
    ///   - homeCurrency: the user's home currency (e.g. from
    ///     `@AppStorage("profile.homeCurrency")`, default `RateProvider.defaultHomeCurrency`).
    ///   - existingFingerprints: fingerprints already persisted for this
    ///     card, so re-importing an overlapping statement dedupes instead of
    ///     duplicating rows.
    static func analyze(
        statement: ParsedStatement,
        card: ImportedCard,
        homeCountry: String,
        homeCurrency: String,
        existingFingerprints: Set<String>,
        rateRepository: HistoricalRateRepository
    ) async -> AnalysisResult {
        let normalizedHomeCurrency = homeCurrency.uppercased()
        var requestPairs: [String: (
            reference: HistoricalRateRequest?,
            settledToHome: HistoricalRateRequest?
        )] = [:]
        var allRequests = Set<HistoricalRateRequest>()

        for tx in statement.transactions {
            let fingerprint = Fingerprint.make(cardID: card.id.uuidString, tx: tx)
            guard !existingFingerprints.contains(fingerprint) else { continue }

            let day = AnalyzerCore.dayString(for: tx.date)
            let settledCurrency = (tx.currency ?? normalizedHomeCurrency).uppercased()
            let originalCurrency = tx.originalCurrency?.uppercased()
            let hasOriginal = tx.originalAmount != nil && originalCurrency != nil

            let referenceRequest: HistoricalRateRequest?
            if hasOriginal, let originalCurrency {
                referenceRequest = HistoricalRateRequest(
                    from: originalCurrency,
                    to: normalizedHomeCurrency,
                    day: day
                )
            } else if settledCurrency != normalizedHomeCurrency {
                referenceRequest = HistoricalRateRequest(
                    from: settledCurrency,
                    to: normalizedHomeCurrency,
                    day: day
                )
            } else {
                referenceRequest = nil
            }

            let settledRequest: HistoricalRateRequest? = hasOriginal && settledCurrency != normalizedHomeCurrency
                ? HistoricalRateRequest(
                    from: settledCurrency,
                    to: normalizedHomeCurrency,
                    day: day
                )
                : nil

            requestPairs[fingerprint] = (referenceRequest, settledRequest)
            if let referenceRequest { allRequests.insert(referenceRequest) }
            if let settledRequest { allRequests.insert(settledRequest) }
        }

        let resolvedQuotes = await rateRepository.resolve(allRequests)
        var rateContexts: [String: TransactionRateContext] = [:]
        for (fingerprint, pair) in requestPairs {
            rateContexts[fingerprint] = TransactionRateContext(
                reference: pair.reference.flatMap { resolvedQuotes[$0] },
                settledToHome: pair.settledToHome.flatMap { resolvedQuotes[$0] }
            )
        }

        let (rows, duplicates) = AnalyzerCore.analyze(
            transactions: statement.transactions,
            cardID: card.id.uuidString,
            homeCurrency: normalizedHomeCurrency,
            existingFingerprints: existingFingerprints,
            rateContexts: rateContexts
        )

        let importDate = Date()
        let importedTransactions = rows.map { row -> ImportedTransaction in
            let provenance = ImportProvenance(
                sourceFilename: statement.bankHint ?? "statement",
                importDate: importDate,
                parserConfidence: parserConfidence(for: statement),
                mappingTemplateID: nil,
                fingerprint: row.fingerprint
            )
            return ImportedTransaction(
                cardID: card.id,
                txDate: row.tx.date,
                merchantName: row.tx.description,
                // Statement currency is not proof of merchant location.
                merchantCountry: "??",
                billedCurrency: row.billedCurrency,
                billedAmount: row.billedAmount,
                isForeign: row.isForeign,
                isDccSuspected: row.isDccSuspected,
                homeCurrencyAmount: row.homeCurrencyAmount,
                referenceRate: row.referenceRate,
                effectiveRate: row.effectiveRate,
                markupAmount: row.markupAmount,
                confidence: row.confidence,
                provenance: provenance,
                settledAmount: row.tx.amount,
                settledCurrency: row.tx.currency ?? normalizedHomeCurrency,
                originalAmount: row.tx.originalAmount,
                originalCurrency: row.tx.originalCurrency,
                homeCurrencyAtImport: normalizedHomeCurrency,
                referenceRateDate: row.referenceRateQuote?.observationDate,
                referenceRateSource: row.referenceRateQuote?.source,
                calculationStatus: calculationStatus(for: row, homeCurrency: normalizedHomeCurrency)
            )
        }

        let foreignCount = rows.filter { $0.isForeign }.count
        let unableToCalculateCount = rows.filter { $0.confidence == .unableToCalculate }.count
        // Flagged = a real, positive loss we can actually show — never a negative
        // (better-than-reference) markup, and never an unableToCalculate row
        // (nothing to flag when there's no computed markup at all).
        let flaggedCount = rows.filter { row in
            guard row.confidence != .unableToCalculate, let markup = row.markupAmount else { return false }
            return markup > 0
        }.count

        return AnalysisResult(
            newTransactions: importedTransactions,
            duplicatesSkipped: duplicates,
            foreignCount: foreignCount,
            flaggedCount: flaggedCount,
            unableToCalculateCount: unableToCalculateCount
        )
    }

    /// Statement-level parser confidence surfaced per row: 1.0 when the
    /// statement parsed with no warnings, stepped down when warnings exist
    /// (ambiguous dates, skipped rows, etc.) — a simple, honest signal, not a
    /// precise per-row probability.
    private static func parserConfidence(for statement: ParsedStatement) -> Double {
        statement.warnings.isEmpty ? 1.0 : 0.7
    }

    private static func calculationStatus(
        for row: RowAnalysis,
        homeCurrency: String
    ) -> HistoricalCalculationStatus? {
        guard row.isForeign else { return nil }
        guard row.confidence != .unableToCalculate, let reference = row.referenceRateQuote else {
            return .provisional
        }
        let settledCurrency = (row.tx.currency ?? homeCurrency).uppercased()
        if settledCurrency != homeCurrency {
            guard let settled = row.settledToHomeQuote else { return .provisional }
            return reference.status == .verified && settled.status == .verified
                ? .verified
                : .provisional
        }
        return reference.status
    }
}
