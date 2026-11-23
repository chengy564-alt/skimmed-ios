import Foundation
import XCTest
@testable import ImportCore

final class OwnedCardRankingCoreTests: XCTestCase {
    private let cardA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let cardB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let cardC = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func testMedianPreventsOneOutlierChoosingTheWrongCard() throws {
        let rows = fixtures(cardID: cardA, percentages: [1, 1, 20], currency: "THB")
            + fixtures(cardID: cardB, percentages: [2, 2, 2], currency: "THB")

        let ranking = try XCTUnwrap(OwnedCardRankingCore.rank(
            transactions: rows,
            ownedCardIDs: [cardA, cardB]
        ).first { $0.destinationCurrency == "THB" })

        XCTAssertEqual(ranking.scores.first?.cardID, cardA)
        XCTAssertEqual(ranking.scores.first?.medianMarkupPct, dec("1"))
        XCTAssertEqual(ranking.scores.last?.medianMarkupPct, dec("2"))
    }

    func testStrongNeedsFiveVerifiedDestinationRowsAcrossTwoDates() throws {
        let dayOne = utcDate(2026, 4, 3)
        let dayTwo = utcDate(2026, 4, 4)
        let rows = fixtures(
            cardID: cardA,
            percentages: [1, 1, 1, 1, 1],
            currency: "THB",
            dates: [dayOne, dayOne, dayOne, dayOne, dayTwo]
        ) + fixtures(cardID: cardB, percentages: [2, 2], currency: "THB")

        let ranking = try XCTUnwrap(OwnedCardRankingCore.rank(
            transactions: rows,
            ownedCardIDs: [cardA, cardB]
        ).first { $0.destinationCurrency == "THB" })
        let score = try XCTUnwrap(ranking.scores.first { $0.cardID == cardA })

        XCTAssertEqual(score.evidenceCount, 5)
        XCTAssertEqual(score.distinctDateCount, 2)
        XCTAssertEqual(score.confidence, .strong)
    }

    func testScoresWithinFiveBasisPointsAreBothTiedBest() throws {
        let rows = fixtures(cardID: cardA, percentages: [1.00], currency: "THB")
            + fixtures(cardID: cardB, percentages: [1.04], currency: "THB")

        let ranking = try XCTUnwrap(OwnedCardRankingCore.rank(
            transactions: rows,
            ownedCardIDs: [cardA, cardB]
        ).first)

        XCTAssertEqual(ranking.scores.filter(\.isTiedBest).count, 2)
    }

    func testVerifiedDestinationTierWinsWithoutMixingWeakerRows() throws {
        let destinationVerified = fixtures(cardID: cardA, percentages: [10], currency: "THB")
            + fixtures(cardID: cardB, percentages: [20], currency: "THB")
        let crossCurrencyVerified = fixtures(cardID: cardA, percentages: [-5], currency: "EUR")
            + fixtures(cardID: cardB, percentages: [-6], currency: "EUR")
        let destinationProvisional = fixtures(
            cardID: cardA,
            percentages: [-20],
            currency: "THB",
            status: .provisional,
            source: .bundledFallback
        ) + fixtures(
            cardID: cardB,
            percentages: [-30],
            currency: "THB",
            status: .provisional,
            source: .bundledFallback
        )

        let ranking = try XCTUnwrap(OwnedCardRankingCore.rank(
            transactions: destinationVerified + crossCurrencyVerified + destinationProvisional,
            ownedCardIDs: [cardA, cardB]
        ).first { $0.destinationCurrency == "THB" })

        XCTAssertEqual(ranking.evidenceTier, .verifiedDestination)
        XCTAssertEqual(ranking.scores.first { $0.cardID == cardA }?.medianMarkupPct, dec("10"))
        XCTAssertEqual(ranking.scores.first { $0.cardID == cardA }?.evidenceCount, 1)
    }

    func testFallsBackToVerifiedCrossCurrencyOnlyWhenTwoCardsAreScoreable() throws {
        let oneCardAtDestination = fixtures(cardID: cardA, percentages: [9], currency: "THB")
        let crossCurrency = fixtures(cardID: cardA, percentages: [1], currency: "EUR")
            + fixtures(cardID: cardB, percentages: [2], currency: "EUR")

        let ranking = try XCTUnwrap(OwnedCardRankingCore.rank(
            transactions: oneCardAtDestination + crossCurrency,
            ownedCardIDs: [cardA, cardB]
        ).first { $0.destinationCurrency == "THB" })

        XCTAssertEqual(ranking.evidenceTier, .verifiedCrossCurrency)
        XCTAssertEqual(ranking.scores.map(\.cardID), [cardA, cardB])
        XCTAssertTrue(ranking.scores.allSatisfy { $0.confidence == .limited })
    }

    func testCrossCurrencyCanRankAnExplicitDestinationWithoutDirectRows() throws {
        let verifiedHistory = fixtures(cardID: cardA, percentages: [1, 1.5], currency: "THB")
            + fixtures(cardID: cardB, percentages: [2, 2.5], currency: "THB")

        let ranking = try XCTUnwrap(OwnedCardRankingCore.rank(
            transactions: verifiedHistory,
            ownedCardIDs: [cardA, cardB],
            destinationCurrencies: ["JPY"]
        ).first { $0.destinationCurrency == "JPY" })

        XCTAssertEqual(ranking.evidenceTier, .verifiedCrossCurrency)
        XCTAssertEqual(ranking.scores.map(\.cardID), [cardA, cardB])
        XCTAssertTrue(ranking.scores.allSatisfy { $0.confidence == .limited })
    }

    func testFallsBackToProvisionalDestinationAndNeverScoresUnownedCard() throws {
        let provisional = fixtures(
            cardID: cardA,
            percentages: [1],
            currency: "THB",
            status: .provisional,
            source: .bundledFallback
        ) + fixtures(
            cardID: cardB,
            percentages: [2],
            currency: "THB",
            status: .provisional,
            source: .bundledFallback
        ) + fixtures(
            cardID: cardC,
            percentages: [-50],
            currency: "THB",
            status: .provisional,
            source: .bundledFallback
        )

        let ranking = try XCTUnwrap(OwnedCardRankingCore.rank(
            transactions: provisional,
            ownedCardIDs: [cardA, cardB]
        ).first)

        XCTAssertEqual(ranking.evidenceTier, .provisionalDestination)
        XCTAssertEqual(Set(ranking.scores.map(\.cardID)), [cardA, cardB])
        XCTAssertFalse(ranking.scores.contains { $0.cardID == cardC })
    }

    func testReturnsNoRankingWithoutTwoScoreableOwnedCards() {
        let rows = fixtures(cardID: cardA, percentages: [1, 2], currency: "THB")
            + fixtures(cardID: cardC, percentages: [0], currency: "THB")

        XCTAssertTrue(OwnedCardRankingCore.rank(
            transactions: rows,
            ownedCardIDs: [cardA, cardB]
        ).isEmpty)
    }

    private func fixtures(
        cardID: UUID,
        percentages: [Decimal],
        currency: String,
        dates: [Date]? = nil,
        status: HistoricalCalculationStatus = .verified,
        source: HistoricalRateSource = .ecb
    ) -> [ImportedTransaction] {
        percentages.enumerated().map { index, percentage in
            let fairCost = dec("100")
            let markup = percentage
            let date = dates?[index] ?? utcDate(2026, 4, index + 1)
            return ImportedTransaction(
                cardID: cardID,
                txDate: date,
                merchantName: "Fixture \(index)",
                merchantCountry: "??",
                billedCurrency: currency,
                billedAmount: fairCost,
                isForeign: true,
                isDccSuspected: false,
                homeCurrencyAmount: fairCost + markup,
                referenceRate: 1,
                effectiveRate: (fairCost + markup) / fairCost,
                markupAmount: markup,
                confidence: .exact,
                provenance: ImportProvenance(
                    sourceFilename: "ranking.csv",
                    importDate: date,
                    parserConfidence: 1,
                    mappingTemplateID: nil,
                    fingerprint: UUID().uuidString
                ),
                settledAmount: fairCost + markup,
                settledCurrency: "HKD",
                originalAmount: fairCost,
                originalCurrency: currency,
                homeCurrencyAtImport: "HKD",
                referenceRateDate: date,
                referenceRateSource: source,
                calculationStatus: status
            )
        }
    }
}
