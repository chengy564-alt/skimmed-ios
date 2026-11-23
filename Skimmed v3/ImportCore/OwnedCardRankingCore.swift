import Foundation

public enum RecommendationConfidence: String, Codable, Equatable {
    case strong
    case developing
    case limited
    case insufficient
}

public enum RecommendationEvidenceTier: String, Codable, Equatable {
    case verifiedDestination
    case verifiedCrossCurrency
    case provisionalDestination
}

public struct OwnedCardScore: Equatable {
    public let cardID: UUID
    public let medianMarkupPct: Decimal
    public let confidence: RecommendationConfidence
    public let evidenceCount: Int
    public let distinctDateCount: Int
    public let isTiedBest: Bool

    public init(
        cardID: UUID,
        medianMarkupPct: Decimal,
        confidence: RecommendationConfidence,
        evidenceCount: Int,
        distinctDateCount: Int,
        isTiedBest: Bool
    ) {
        self.cardID = cardID
        self.medianMarkupPct = medianMarkupPct
        self.confidence = confidence
        self.evidenceCount = evidenceCount
        self.distinctDateCount = distinctDateCount
        self.isTiedBest = isTiedBest
    }
}

public struct OwnedCurrencyRanking: Equatable {
    public let destinationCurrency: String
    public let evidenceTier: RecommendationEvidenceTier
    public let scores: [OwnedCardScore]

    public init(
        destinationCurrency: String,
        evidenceTier: RecommendationEvidenceTier,
        scores: [OwnedCardScore]
    ) {
        self.destinationCurrency = destinationCurrency
        self.evidenceTier = evidenceTier
        self.scores = scores
    }
}

/// Ranks only user-owned cards from observed statement evidence. Each
/// destination selects one global evidence tier so direct, cross-currency,
/// and provisional rows are never blended into a false-precision score.
public enum OwnedCardRankingCore {
    public static let tieTolerancePercentagePoints = Decimal(string: "0.05")!

    public static func rank(
        transactions: [ImportedTransaction],
        ownedCardIDs: Set<UUID>,
        destinationCurrencies: Set<String> = []
    ) -> [OwnedCurrencyRanking] {
        guard ownedCardIDs.count >= 2 else { return [] }

        let usable = transactions.compactMap { transaction -> Observation? in
            guard
                ownedCardIDs.contains(transaction.cardID),
                transaction.isForeign,
                transaction.confidence != .unableToCalculate,
                let markup = transaction.markupAmount
            else { return nil }
            let fairCost = transaction.homeCurrencyAmount - markup
            guard fairCost > 0 else { return nil }
            return Observation(
                cardID: transaction.cardID,
                currency: transaction.billedCurrency.uppercased(),
                day: dayKey(transaction.txDate),
                markupPct: markup / fairCost * 100,
                status: transaction.resolvedCalculationStatus,
                source: transaction.referenceRateSource
            )
        }

        let destinations = Set(usable.map(\.currency))
            .union(destinationCurrencies.map { $0.uppercased() })
            .sorted()
        return destinations.compactMap { destination in
            ranking(
                destination: destination,
                observations: usable,
                ownedCardIDs: ownedCardIDs
            )
        }
    }

    private struct Observation {
        let cardID: UUID
        let currency: String
        let day: String
        let markupPct: Decimal
        let status: HistoricalCalculationStatus
        let source: HistoricalRateSource?
    }

    private static let tierOrder: [RecommendationEvidenceTier] = [
        .verifiedDestination,
        .verifiedCrossCurrency,
        .provisionalDestination,
    ]

    private static func ranking(
        destination: String,
        observations: [Observation],
        ownedCardIDs: Set<UUID>
    ) -> OwnedCurrencyRanking? {
        for tier in tierOrder {
            let tierRows = observations.filter { observation in
                switch tier {
                case .verifiedDestination:
                    return observation.currency == destination
                        && observation.status == .verified
                        && observation.source == .ecb
                case .verifiedCrossCurrency:
                    return observation.currency != destination
                        && observation.status == .verified
                        && observation.source == .ecb
                case .provisionalDestination:
                    return observation.currency == destination
                        && observation.status == .provisional
                }
            }
            let byCard = Dictionary(grouping: tierRows, by: \.cardID)
                .filter { ownedCardIDs.contains($0.key) && !$0.value.isEmpty }
            guard byCard.count >= 2 else { continue }

            var scores = byCard.map { cardID, rows in
                OwnedCardScore(
                    cardID: cardID,
                    medianMarkupPct: median(rows.map(\.markupPct)),
                    confidence: confidence(
                        tier: tier,
                        evidenceCount: rows.count,
                        distinctDateCount: Set(rows.map(\.day)).count
                    ),
                    evidenceCount: rows.count,
                    distinctDateCount: Set(rows.map(\.day)).count,
                    isTiedBest: false
                )
            }
            scores.sort {
                if $0.medianMarkupPct != $1.medianMarkupPct {
                    return $0.medianMarkupPct < $1.medianMarkupPct
                }
                return $0.cardID.uuidString < $1.cardID.uuidString
            }
            guard let best = scores.first?.medianMarkupPct else { continue }
            scores = scores.map { score in
                OwnedCardScore(
                    cardID: score.cardID,
                    medianMarkupPct: score.medianMarkupPct,
                    confidence: score.confidence,
                    evidenceCount: score.evidenceCount,
                    distinctDateCount: score.distinctDateCount,
                    isTiedBest: score.medianMarkupPct - best <= tieTolerancePercentagePoints
                )
            }
            return OwnedCurrencyRanking(
                destinationCurrency: destination,
                evidenceTier: tier,
                scores: scores
            )
        }
        return nil
    }

    private static func median(_ values: [Decimal]) -> Decimal {
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    private static func confidence(
        tier: RecommendationEvidenceTier,
        evidenceCount: Int,
        distinctDateCount: Int
    ) -> RecommendationConfidence {
        guard tier == .verifiedDestination else { return .limited }
        if evidenceCount >= 5 && distinctDateCount >= 2 { return .strong }
        if evidenceCount >= 2 { return .developing }
        return .limited
    }

    private static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
