import Foundation

/// Metadata retained for each imported row. The original statement file is
/// never stored; this is enough to trace how a persisted result was produced.
public struct ImportProvenance: Codable, Equatable {
    public let sourceFilename: String
    public let importDate: Date
    public let parserConfidence: Double
    public let mappingTemplateID: String?
    public let fingerprint: String

    public init(
        sourceFilename: String,
        importDate: Date,
        parserConfidence: Double,
        mappingTemplateID: String?,
        fingerprint: String
    ) {
        self.sourceFilename = sourceFilename
        self.importDate = importDate
        self.parserConfidence = parserConfidence
        self.mappingTemplateID = mappingTemplateID
        self.fingerprint = fingerprint
    }
}

/// One analyzed statement row. The optional evidence fields were added after
/// the first persisted format, so absent values decode safely from older JSON.
/// They preserve the untouched monetary legs needed to replace a provisional
/// fallback calculation when a verified daily quote later becomes available.
public struct ImportedTransaction: Codable, Identifiable, Equatable {
    public let id: UUID
    public let cardID: UUID
    public let txDate: Date
    public let merchantName: String
    public let merchantCountry: String
    public let billedCurrency: String
    public let billedAmount: Decimal
    public let isForeign: Bool
    public let isDccSuspected: Bool
    public let homeCurrencyAmount: Decimal
    public let referenceRate: Decimal?
    public let effectiveRate: Decimal?
    /// Signed result: positive is a loss; negative is better than reference.
    public let markupAmount: Decimal?
    public let confidence: RowConfidence
    public let provenance: ImportProvenance

    public let settledAmount: Decimal?
    public let settledCurrency: String?
    public let originalAmount: Decimal?
    public let originalCurrency: String?
    public let homeCurrencyAtImport: String?
    public let referenceRateDate: Date?
    public let referenceRateSource: HistoricalRateSource?
    public let calculationStatus: HistoricalCalculationStatus?

    public var resolvedCalculationStatus: HistoricalCalculationStatus {
        calculationStatus ?? .provisional
    }

    public var repricingRateRequests: TransactionRateRequests? {
        guard
            isForeign,
            settledAmount != nil,
            let settledCurrency,
            let originalAmount,
            let originalCurrency,
            let homeCurrencyAtImport,
            originalAmount != 0
        else { return nil }

        let day = AnalyzerCore.dayString(for: txDate)
        let reference = HistoricalRateRequest(
            from: originalCurrency,
            to: homeCurrencyAtImport,
            day: day
        )
        let settledToHome = settledCurrency == homeCurrencyAtImport
            ? nil
            : HistoricalRateRequest(
                from: settledCurrency,
                to: homeCurrencyAtImport,
                day: day
            )
        return TransactionRateRequests(
            reference: reference,
            settledToHome: settledToHome
        )
    }

    public init(
        id: UUID = UUID(),
        cardID: UUID,
        txDate: Date,
        merchantName: String,
        merchantCountry: String,
        billedCurrency: String,
        billedAmount: Decimal,
        isForeign: Bool,
        isDccSuspected: Bool,
        homeCurrencyAmount: Decimal,
        referenceRate: Decimal?,
        effectiveRate: Decimal?,
        markupAmount: Decimal?,
        confidence: RowConfidence,
        provenance: ImportProvenance,
        settledAmount: Decimal? = nil,
        settledCurrency: String? = nil,
        originalAmount: Decimal? = nil,
        originalCurrency: String? = nil,
        homeCurrencyAtImport: String? = nil,
        referenceRateDate: Date? = nil,
        referenceRateSource: HistoricalRateSource? = nil,
        calculationStatus: HistoricalCalculationStatus? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.txDate = txDate
        self.merchantName = merchantName
        self.merchantCountry = merchantCountry
        self.billedCurrency = billedCurrency
        self.billedAmount = billedAmount
        self.isForeign = isForeign
        self.isDccSuspected = isDccSuspected
        self.homeCurrencyAmount = homeCurrencyAmount
        self.referenceRate = referenceRate
        self.effectiveRate = effectiveRate
        self.markupAmount = markupAmount
        self.confidence = confidence
        self.provenance = provenance
        self.settledAmount = settledAmount
        self.settledCurrency = settledCurrency?.uppercased()
        self.originalAmount = originalAmount
        self.originalCurrency = originalCurrency?.uppercased()
        self.homeCurrencyAtImport = homeCurrencyAtImport?.uppercased()
        self.referenceRateDate = referenceRateDate
        self.referenceRateSource = referenceRateSource
        self.calculationStatus = calculationStatus
    }

    /// Sanitizes pre-rate-history rows without inventing their missing home
    /// currency. A reference-rate coincidence cannot prove currency identity,
    /// so legacy rows remain unreconstructable and provisional. New imports
    /// already persist every raw leg and can be upgraded normally.
    public func migratedLegacyEvidence(homeCurrency _: String) -> ImportedTransaction {
        let isUnidentifiedLegacyFX = isForeign
            && homeCurrencyAtImport == nil
            && settledAmount == nil
            && settledCurrency == nil
            && originalAmount == nil
            && originalCurrency == nil
        return ImportedTransaction(
            id: id,
            cardID: cardID,
            txDate: txDate,
            merchantName: merchantName,
            merchantCountry: "??",
            billedCurrency: billedCurrency,
            billedAmount: billedAmount,
            isForeign: isForeign,
            isDccSuspected: isDccSuspected,
            homeCurrencyAmount: homeCurrencyAmount,
            referenceRate: isUnidentifiedLegacyFX ? nil : referenceRate,
            effectiveRate: isUnidentifiedLegacyFX ? nil : effectiveRate,
            markupAmount: isUnidentifiedLegacyFX ? nil : markupAmount,
            confidence: isUnidentifiedLegacyFX ? .unableToCalculate : confidence,
            provenance: provenance,
            settledAmount: settledAmount,
            settledCurrency: settledCurrency,
            originalAmount: originalAmount,
            originalCurrency: originalCurrency,
            homeCurrencyAtImport: homeCurrencyAtImport,
            referenceRateDate: isUnidentifiedLegacyFX ? nil : referenceRateDate,
            referenceRateSource: isUnidentifiedLegacyFX ? nil : referenceRateSource,
            calculationStatus: isUnidentifiedLegacyFX ? .provisional : calculationStatus
        )
    }

    /// Recalculates a row exclusively from the raw values printed on the
    /// statement. Legacy rows without those values remain untouched.
    public func repriced(
        reference: HistoricalRateQuote,
        settledToHome: HistoricalRateQuote?
    ) -> ImportedTransaction? {
        guard
            let settledAmount,
            let settledCurrency,
            let originalAmount,
            let originalCurrency,
            let homeCurrencyAtImport,
            originalAmount != 0,
            reference.request.from == originalCurrency,
            reference.request.to == homeCurrencyAtImport
        else { return nil }

        let homeAmount: Decimal
        var requiredStatuses = [reference.status]
        if settledCurrency == homeCurrencyAtImport {
            homeAmount = settledAmount
        } else {
            guard
                let settledToHome,
                settledToHome.request.from == settledCurrency,
                settledToHome.request.to == homeCurrencyAtImport
            else { return nil }
            homeAmount = settledAmount * settledToHome.rate
            requiredStatuses.append(settledToHome.status)
        }

        let effectiveRate = homeAmount / originalAmount
        let markupAmount = homeAmount - originalAmount * reference.rate
        let status: HistoricalCalculationStatus = requiredStatuses.allSatisfy { $0 == .verified }
            ? .verified
            : .provisional

        return ImportedTransaction(
            id: id,
            cardID: cardID,
            txDate: txDate,
            merchantName: merchantName,
            merchantCountry: merchantCountry,
            billedCurrency: billedCurrency,
            billedAmount: billedAmount,
            isForeign: isForeign,
            isDccSuspected: isDccSuspected,
            homeCurrencyAmount: homeAmount,
            referenceRate: reference.rate,
            effectiveRate: effectiveRate,
            markupAmount: markupAmount,
            confidence: confidence,
            provenance: provenance,
            settledAmount: settledAmount,
            settledCurrency: settledCurrency,
            originalAmount: originalAmount,
            originalCurrency: originalCurrency,
            homeCurrencyAtImport: homeCurrencyAtImport,
            referenceRateDate: reference.observationDate,
            referenceRateSource: reference.source,
            calculationStatus: status
        )
    }
}

/// Keeps persisted money in one home-currency scope. Rows from before home
/// currency identity was stored may remain visible after legacy sanitization,
/// but they contribute no loss math. Known, different currencies are never
/// projected or appended into the same aggregate.
nonisolated public enum ImportedTransactionCurrencyScope {
    public static func canonicalHomeCurrency(
        in transactions: [ImportedTransaction]
    ) -> String? {
        transactions.compactMap(\.homeCurrencyAtImport).first
    }

    public static func compatibleTransactions(
        in transactions: [ImportedTransaction],
        homeCurrency: String
    ) -> [ImportedTransaction] {
        let normalized = homeCurrency.uppercased()
        return transactions.filter {
            $0.homeCurrencyAtImport == nil || $0.homeCurrencyAtImport == normalized
        }
    }

    public static func canAppend(
        _ incoming: [ImportedTransaction],
        to existing: [ImportedTransaction]
    ) -> Bool {
        let existingCurrency = canonicalHomeCurrency(in: existing)
        let incomingCurrencies = Set(incoming.compactMap(\.homeCurrencyAtImport))
        guard incomingCurrencies.count <= 1 else { return false }
        guard let incomingCurrency = incomingCurrencies.first else { return true }
        return existingCurrency == nil || existingCurrency == incomingCurrency
    }
}

nonisolated public struct TransactionRateRequests: Equatable {
    public let reference: HistoricalRateRequest
    public let settledToHome: HistoricalRateRequest?

    public init(
        reference: HistoricalRateRequest,
        settledToHome: HistoricalRateRequest?
    ) {
        self.reference = reference
        self.settledToHome = settledToHome
    }
}

public extension Collection where Element == ImportedTransaction {
    var totalPositiveLoss: Decimal {
        reduce(0) { total, transaction in
            guard let markup = transaction.markupAmount, markup > 0 else { return total }
            return total + markup
        }
    }

    func positiveLossByCard() -> [UUID: Decimal] {
        reduce(into: [:]) { totals, transaction in
            guard let markup = transaction.markupAmount, markup > 0 else { return }
            totals[transaction.cardID, default: 0] += markup
        }
    }
}

public extension Array where Element == ImportedTransaction {
    /// Applies only complete, verified quote sets to reconstructable fallback
    /// rows. Missing data, partial quote sets, and already-verified rows are
    /// returned byte-for-byte unchanged.
    func repricedProvisionalTransactions(
        using quotes: [HistoricalRateRequest: HistoricalRateQuote]
    ) -> [ImportedTransaction] {
        map { transaction in
            guard
                transaction.resolvedCalculationStatus == .provisional,
                let requests = transaction.repricingRateRequests,
                let reference = quotes[requests.reference],
                reference.status == .verified
            else { return transaction }

            let settledQuote = requests.settledToHome.flatMap { quotes[$0] }
            if requests.settledToHome != nil, settledQuote?.status != .verified {
                return transaction
            }
            guard
                let updated = transaction.repriced(
                    reference: reference,
                    settledToHome: settledQuote
                ),
                updated.resolvedCalculationStatus == .verified
            else { return transaction }
            return updated
        }
    }
}

/// One statement's deduplicated analysis output and preview counts.
public struct AnalysisResult: Equatable {
    public let newTransactions: [ImportedTransaction]
    public let duplicatesSkipped: Int
    public let foreignCount: Int
    public let flaggedCount: Int
    public let unableToCalculateCount: Int

    public init(
        newTransactions: [ImportedTransaction],
        duplicatesSkipped: Int,
        foreignCount: Int,
        flaggedCount: Int,
        unableToCalculateCount: Int
    ) {
        self.newTransactions = newTransactions
        self.duplicatesSkipped = duplicatesSkipped
        self.foreignCount = foreignCount
        self.flaggedCount = flaggedCount
        self.unableToCalculateCount = unableToCalculateCount
    }
}
