import Combine
import Foundation
import SwiftUI

/// Single data source for views — statement-imported data only. With no
/// imports yet, every derived collection is simply empty and views render
/// their empty states. Data persists as Codable JSON via `Persistence`;
/// every mutation method here re-persists before returning.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    /// The store doesn't yet manage multiple user profiles — a stable
    /// placeholder id fills the `userId` slot on derived records.
    private static let placeholderUserId = "user_import"

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    @Published private(set) var cards: [ImportedCard]
    /// User-created trip audits (v1.1) — additive to the transaction-derived
    /// `trips`. Absent file (pre-v1.1 install) loads as [].
    @Published private(set) var plannedTrips: [PlannedTrip]
    /// Confirmed (institution + last4) → catalogue card-product mappings.
    @Published private(set) var userCardLinks: [UserCardLink]
    /// Internal transaction store (full fidelity: Decimal amounts,
    /// three-tier confidence, provenance). `transactions` below is the
    /// lossy, view-facing `Transaction` projection of this.
    @Published private(set) var importedTransactions: [ImportedTransaction]

    private let persistence: Persistence
    let historicalRateRepository: HistoricalRateRepository
    private var rateRefreshTask: Task<Void, Never>?
    private var rateRefreshToken: UUID?

    init(persistence suppliedPersistence: Persistence? = nil) {
        let persistence = suppliedPersistence ?? Persistence()
        self.persistence = persistence
        self.historicalRateRepository = HistoricalRateRepository(
            cacheURL: persistence.historicalRateCacheURL
        )
        self.cards = persistence.loadCards()
        let loadedTransactions = persistence.loadTransactions()
        let homeCurrency = UserDefaults.standard.string(forKey: "profile.homeCurrency")
            ?? RateProvider.defaultHomeCurrency
        let migratedTransactions = loadedTransactions.map {
            $0.migratedLegacyEvidence(homeCurrency: homeCurrency)
        }
        if let datasetCurrency = ImportedTransactionCurrencyScope
            .canonicalHomeCurrency(in: migratedTransactions),
           datasetCurrency != homeCurrency {
            // Existing stored money owns its currency identity. Restore the
            // profile formatter instead of relabelling those numeric values.
            UserDefaults.standard.set(datasetCurrency, forKey: "profile.homeCurrency")
        }
        self.importedTransactions = migratedTransactions
        self.plannedTrips = persistence.loadPlannedTrips()
        self.userCardLinks = persistence.loadUserCardLinks()
        if migratedTransactions != loadedTransactions {
            persistence.saveTransactions(migratedTransactions)
        }
    }

    /// True until the first statement is imported (or after a full erase) —
    /// views key their empty states off this.
    var hasNoData: Bool { cards.isEmpty }

    var hasProvisionalRateCalculations: Bool {
        calculationTransactions.contains {
            $0.isForeign && $0.resolvedCalculationStatus == .provisional
        }
    }

    var hasVerifiedRateCalculations: Bool {
        calculationTransactions.contains {
            $0.isForeign && $0.resolvedCalculationStatus == .verified
        }
    }

    // MARK: - view-facing surface

    /// The first import fixes the monetary unit for this dataset. Legacy rows
    /// with no identity remain visible only after their loss math is removed.
    var importedDataHomeCurrency: String? {
        ImportedTransactionCurrencyScope.canonicalHomeCurrency(in: importedTransactions)
    }

    var calculationTransactions: [ImportedTransaction] {
        let home = importedDataHomeCurrency
            ?? UserDefaults.standard.string(forKey: "profile.homeCurrency")
            ?? RateProvider.defaultHomeCurrency
        return ImportedTransactionCurrencyScope.compatibleTransactions(
            in: importedTransactions,
            homeCurrency: home
        )
    }

    var linkedAccounts: [LinkedAccount] {
        cards.map(Self.linkedAccount(from:))
    }

    var transactions: [Transaction] {
        // Planned-trip country wins for display (the hybrid "C" rule): a row
        // attached to a tagged trip flies that trip's flag; everything else
        // falls back to the currency hint inside `transaction(from:)`.
        var tripCountry: [UUID: String] = [:]
        for trip in plannedTrips {
            for id in trip.transactionIDs { tripCountry[id] = trip.destinationCountry }
        }
        return calculationTransactions.map { Self.transaction(from: $0, tripCountry: tripCountry[$0.id]) }
    }

    var trips: [Trip] {
        TripBuilder.build(from: calculationTransactions, userId: Self.placeholderUserId)
    }

    var liveTrip: Trip? {
        trips.last(where: { $0.endDate == nil })
    }

    var revealSnapshot: RevealSnapshot {
        Self.buildRevealSnapshot(transactions: calculationTransactions, userId: Self.placeholderUserId)
    }

    var cardRankings: [CardRanking] {
        Self.buildCardRankings(
            transactions: calculationTransactions,
            ownedCardIDs: Set(cards.map(\.id)),
            destinationCurrencies: selectedDestinationCurrencies,
            userId: Self.placeholderUserId
        )
    }

    private var selectedDestinationCurrencies: Set<String> {
        let stored = UserDefaults.standard.string(forKey: "profile.destinations") ?? ""
        var currencies = Set(stored.split(separator: ",").compactMap {
            Derive.destinationInfo(
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            )?.currency
        })
        currencies.formUnion(plannedTrips.compactMap {
            CurrencyCountry.currency(forCountry: $0.destinationCountry)
        })
        return currencies
    }

    // MARK: - mutation

    /// Quietly upgrades fallback calculations when the ECB is reachable.
    /// Concurrent launch/foreground/import triggers form a short serial queue,
    /// so an import that arrives during a refresh gets its own follow-up pass.
    /// Partial or failed responses never replace the transaction array.
    func refreshProvisionalRates() async {
        let previousTask = rateRefreshTask
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return }
            await self.performProvisionalRateRefresh()
        }
        rateRefreshToken = token
        rateRefreshTask = task
        await task.value
        if rateRefreshToken == token {
            rateRefreshTask = nil
            rateRefreshToken = nil
        }
    }

    private func performProvisionalRateRefresh() async {
        let reconstructable = importedTransactions.compactMap { transaction -> TransactionRateRequests? in
            guard transaction.resolvedCalculationStatus == .provisional else { return nil }
            return transaction.repricingRateRequests
        }
        let requests = Set(reconstructable.flatMap { pair in
            [pair.reference] + [pair.settledToHome].compactMap { $0 }
        })
        guard !requests.isEmpty else { return }

        let verifiedQuotes = await historicalRateRepository.resolve(
            requests,
            policy: .verifiedOnly
        )
        guard !verifiedQuotes.isEmpty else { return }

        let updated = importedTransactions.repricedProvisionalTransactions(using: verifiedQuotes)
        guard updated != importedTransactions else { return }
        importedTransactions = updated
        persistence.saveTransactions(updated)
    }

    /// Commits one statement's analyzed rows against `card` (creating or
    /// updating it) and persists. `card` may be a brand-new `ImportedCard`
    /// (from `CardMatcher`'s `.createNew`/`.choose` flow) or an existing one
    /// being re-imported into.
    func commitImport(result: AnalysisResult, card: ImportedCard) {
        guard ImportedTransactionCurrencyScope.canAppend(
            result.newTransactions,
            to: importedTransactions
        ) else {
            assertionFailure("Refusing to mix imported home currencies")
            return
        }
        var updatedCards = cards
        if let index = updatedCards.firstIndex(where: { $0.id == card.id }) {
            updatedCards[index].lastImportAt = Date()
        } else {
            var newCard = card
            newCard.lastImportAt = Date()
            updatedCards.append(newCard)
        }
        cards = updatedCards
        importedTransactions.append(contentsOf: result.newTransactions)
        persist()
        Task { await refreshProvisionalRates() }
    }

    /// Fingerprints already on file for a card — pass into
    /// `Analyzer.analyze(..., existingFingerprints:)` so re-importing an
    /// overlapping statement dedupes instead of duplicating rows.
    func existingFingerprints(forCard cardID: UUID) -> Set<String> {
        Set(importedTransactions.filter { $0.cardID == cardID }.map { $0.provenance.fingerprint })
    }

    /// Full wipe: cards, transactions, planned trips, card links, mapping
    /// templates. Views fall back to their empty states.
    func resetAllData() {
        cards = []
        importedTransactions = []
        plannedTrips = []
        userCardLinks = []
        persistence.deleteAllImportedData()
    }

    // MARK: - planned trips (v1.1 trip audits)

    func upsertPlannedTrip(_ trip: PlannedTrip) {
        if let index = plannedTrips.firstIndex(where: { $0.id == trip.id }) {
            plannedTrips[index] = trip
        } else {
            plannedTrips.append(trip)
        }
        persistence.savePlannedTrips(plannedTrips)
    }

    func deletePlannedTrip(id: UUID) {
        plannedTrips.removeAll { $0.id == id }
        persistence.savePlannedTrips(plannedTrips)
    }

    /// Records one committed import against a planned trip: the card joins
    /// the trip's attachments and the new rows join its transaction set.
    func attach(result: AnalysisResult, card: ImportedCard, to tripID: UUID) {
        guard let index = plannedTrips.firstIndex(where: { $0.id == tripID }) else { return }
        var trip = plannedTrips[index]
        if !trip.attachedCardIDs.contains(card.id) {
            trip.attachedCardIDs.append(card.id)
        }
        trip.transactionIDs.append(contentsOf: result.newTransactions.map(\.id))
        plannedTrips[index] = trip
        persistence.savePlannedTrips(plannedTrips)
    }

    // MARK: - user card links (catalogue confirmations)

    func upsertUserCardLink(_ link: UserCardLink) {
        // One link per (institution, last4): a re-confirmation replaces.
        userCardLinks.removeAll { $0.institutionID == link.institutionID && $0.last4 == link.last4 }
        userCardLinks.append(link)
        persistence.saveUserCardLinks(userCardLinks)
    }

    /// Removes every imported transaction but keeps cards — cards surviving
    /// means there's still something to show, just with an empty report.
    /// Trips, the reveal snapshot, and card rankings all recompute
    /// automatically since they're derived from `importedTransactions`, not
    /// stored separately.
    func clearTransactionHistory() {
        importedTransactions = []
        persist()
    }

    /// Deletes one card and its transactions; deleting the last card leaves
    /// the empty states.
    func deleteCard(_ card: ImportedCard) {
        let pruned = persistence.deleteCard(id: card.id, cards: cards, transactions: importedTransactions)
        cards = pruned.cards
        importedTransactions = pruned.transactions
    }

    private func persist() {
        persistence.saveCards(cards)
        persistence.saveTransactions(importedTransactions)
    }

    // MARK: - mapping: ImportedCard -> LinkedAccount

    private static func linkedAccount(from card: ImportedCard) -> LinkedAccount {
        LinkedAccount(
            id: card.id.uuidString,
            userId: placeholderUserId,
            aggregator: .statementImport,
            aggregatorItemId: card.id.uuidString,
            institutionName: card.bank,
            displayName: card.nickname,
            last4: card.last4 ?? "----",
            accountType: card.accountType,
            status: .active,
            linkedAt: iso8601.string(from: card.createdAt)
        )
    }

    // MARK: - mapping: ImportedTransaction -> Transaction

    private static func transaction(from imported: ImportedTransaction, tripCountry: String? = nil) -> Transaction {
        let markup = imported.markupAmount.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        // Transaction.markupConfidence only has two cases (exact/estimated);
        // unableToCalculate rows map to .estimated (never .exact, since we
        // couldn't verify anything) — the real three-way signal
        // (`ImportedTransaction.confidence`) lives on `importedTransactions`
        // for anything that needs to exclude unpriced rows from totals
        // (see `buildRevealSnapshot`/`buildCardRankings` below), not on this
        // lossy view-facing projection.
        let confidence: MarkupConfidence = (imported.confidence == .exact) ? .exact : .estimated
        return Transaction(
            id: imported.id.uuidString,
            linkedAccountId: imported.cardID.uuidString,
            txDate: TripBuilder.isoDateFormatter.string(from: imported.txDate),
            merchantName: imported.merchantName,
            merchantCountry: imported.merchantCountry,
            currencyCountryHint: CurrencyCountry.country(for: imported.billedCurrency),
            displayCountry: tripCountry ?? CurrencyCountry.country(for: imported.billedCurrency),
            billedCurrency: imported.billedCurrency,
            billedAmount: NSDecimalNumber(decimal: imported.billedAmount).doubleValue,
            isForeign: imported.isForeign,
            isDccSuspected: imported.isDccSuspected,
            localCurrencyInferred: imported.isDccSuspected ? imported.billedCurrency : nil,
            localAmountEstimated: imported.isDccSuspected
                ? NSDecimalNumber(decimal: imported.billedAmount).doubleValue : nil,
            localAmountSource: imported.isDccSuspected ? .estimated : .actual,
            homeCurrencyAmount: NSDecimalNumber(decimal: imported.homeCurrencyAmount).doubleValue,
            midMarketRate: imported.referenceRate.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0,
            effectiveRate: imported.effectiveRate.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0,
            markupAmount: markup,
            markupConfidence: confidence,
            isMarkupCalculable: imported.confidence != .unableToCalculate
                && imported.markupAmount != nil
                && imported.referenceRate != nil
                && imported.effectiveRate != nil,
            revealIncluded: true,
            referenceRateSource: imported.referenceRateSource,
            calculationStatus: imported.resolvedCalculationStatus,
            referenceRateDate: imported.referenceRateDate.map {
                TripBuilder.isoDateFormatter.string(from: $0)
            }
        )
    }

    // MARK: - reveal snapshot

    private static func buildRevealSnapshot(transactions: [ImportedTransaction], userId: String) -> RevealSnapshot {
        guard !transactions.isEmpty else {
            return RevealSnapshot(
                id: "rvl_import_empty", userId: userId, periodStart: "", periodEnd: "",
                totalLossAmount: 0, transactionCount: 0, worstOffenderLinkedAccountId: "",
                dccTrapCount: 0, isEstimate: true, yoyComparisonPct: nil,
                generatedAt: TripBuilder.isoDateFormatter.string(from: Date())
            )
        }
        // unableToCalculate rows are excluded from the loss total (nothing to
        // honestly sum) but still counted in transactionCount — "kept listed."
        let priced = transactions.filter { $0.confidence != .unableToCalculate }
        let totalLoss = priced.totalPositiveLoss

        let dates = transactions.map(\.txDate)
        let periodStart = TripBuilder.isoDateFormatter.string(from: dates.min() ?? Date())
        let periodEnd = TripBuilder.isoDateFormatter.string(from: dates.max() ?? Date())

        let markupByCard = priced.positiveLossByCard()
        let worstCardID = markupByCard.max(by: { $0.value < $1.value })?.key

        return RevealSnapshot(
            id: "rvl_import",
            userId: userId,
            periodStart: periodStart,
            periodEnd: periodEnd,
            totalLossAmount: Derive.round2(NSDecimalNumber(decimal: totalLoss).doubleValue),
            transactionCount: transactions.count,
            worstOffenderLinkedAccountId: worstCardID?.uuidString ?? "",
            dccTrapCount: transactions.filter(\.isDccSuspected).count,
            isEstimate: transactions.contains {
                $0.confidence != .exact
                    || ($0.isForeign && $0.resolvedCalculationStatus == .provisional)
            },
            yoyComparisonPct: nil,
            generatedAt: TripBuilder.isoDateFormatter.string(from: Date())
        )
    }

    // MARK: - card rankings

    private static func buildCardRankings(
        transactions: [ImportedTransaction],
        ownedCardIDs: Set<UUID>,
        destinationCurrencies: Set<String>,
        userId: String
    ) -> [CardRanking] {
        OwnedCardRankingCore.rank(
            transactions: transactions,
            ownedCardIDs: ownedCardIDs,
            destinationCurrencies: destinationCurrencies
        ).map { ranking in
            CardRanking(
                userId: userId,
                destinationCurrency: ranking.destinationCurrency,
                evidenceTier: ranking.evidenceTier,
                rankedAccounts: ranking.scores.map { score in
                    RankedAccount(
                        linkedAccountId: score.cardID.uuidString,
                        markupPct: Derive.round2(
                            NSDecimalNumber(decimal: score.medianMarkupPct).doubleValue
                        ),
                        confidence: score.confidence,
                        evidenceCount: score.evidenceCount,
                        isTiedBest: score.isTiedBest
                    )
                },
                computedAt: TripBuilder.isoDateFormatter.string(from: Date())
            )
        }
    }
}
