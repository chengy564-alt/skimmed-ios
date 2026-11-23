import Foundation
import XCTest
@testable import ImportCore

final class PersistedImportModelsTests: XCTestCase {
    private let cardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private var verifiedTHBToHKD: HistoricalRateQuote {
        HistoricalRateQuote(
            request: HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-04-03"),
            observationDay: "2026-04-02",
            rate: dec("0.230"),
            source: .ecb,
            status: .verified
        )
    }

    func testLegacyTransactionDecodesAsProvisionalWithoutInventingRawLegs() throws {
        let json = #"""
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "cardID": "11111111-1111-1111-1111-111111111111",
          "txDate": "2026-04-03T00:00:00Z",
          "merchantName": "THIP SAMAI",
          "merchantCountry": "TH",
          "billedCurrency": "THB",
          "billedAmount": 1240,
          "isForeign": true,
          "isDccSuspected": false,
          "homeCurrencyAmount": 295,
          "referenceRate": 0.228,
          "effectiveRate": 0.2379032258064516129,
          "markupAmount": 12.28,
          "confidence": "exact",
          "provenance": {
            "sourceFilename": "legacy.csv",
            "importDate": "2026-04-04T00:00:00Z",
            "parserConfidence": 1,
            "mappingTemplateID": null,
            "fingerprint": "legacy-fingerprint"
          }
        }
        """#.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ImportedTransaction.self, from: json)

        XCTAssertNil(decoded.settledAmount)
        XCTAssertNil(decoded.originalAmount)
        XCTAssertNil(decoded.homeCurrencyAtImport)
        XCTAssertEqual(decoded.resolvedCalculationStatus, .provisional)
        XCTAssertNil(decoded.repriced(reference: verifiedTHBToHKD, settledToHome: nil))
    }

    func testLegacyMigrationDoesNotInventMissingHomeCurrencyIdentity() throws {
        let legacy = summaryTransaction(
            cardID: cardID,
            markupAmount: dec("2.2"),
            status: .provisional
        )

        let migrated = legacy.migratedLegacyEvidence(homeCurrency: "HKD")

        XCTAssertEqual(migrated.merchantCountry, "??")
        XCTAssertNil(migrated.settledAmount)
        XCTAssertNil(migrated.settledCurrency)
        XCTAssertNil(migrated.originalAmount)
        XCTAssertNil(migrated.originalCurrency)
        XCTAssertNil(migrated.homeCurrencyAtImport)
        XCTAssertNil(migrated.repricingRateRequests)
        XCTAssertNil(migrated.referenceRate)
        XCTAssertNil(migrated.effectiveRate)
        XCTAssertNil(migrated.markupAmount)
        XCTAssertEqual(migrated.confidence, .unableToCalculate)
    }

    func testLegacyMigrationLeavesAmbiguousRowsUnreconstructable() {
        let domesticShaped = ImportedTransaction(
            cardID: cardID,
            txDate: utcDate(2026, 4, 3),
            merchantName: "Ambiguous",
            merchantCountry: "HK",
            billedCurrency: "HKD",
            billedAmount: dec("100"),
            isForeign: true,
            isDccSuspected: true,
            homeCurrencyAmount: dec("100"),
            referenceRate: nil,
            effectiveRate: nil,
            markupAmount: nil,
            confidence: .unableToCalculate,
            provenance: ImportProvenance(
                sourceFilename: "legacy.csv",
                importDate: utcDate(2026, 4, 4),
                parserConfidence: 1,
                mappingTemplateID: nil,
                fingerprint: "ambiguous"
            )
        )

        let migrated = domesticShaped.migratedLegacyEvidence(homeCurrency: "HKD")

        XCTAssertEqual(migrated.merchantCountry, "??")
        XCTAssertNil(migrated.settledAmount)
        XCTAssertNil(migrated.originalAmount)
        XCTAssertNil(migrated.repricingRateRequests)
    }

    func testLegacyMigrationRejectsAChangedProfileHomeCurrency() {
        let legacyHKD = summaryTransaction(
            cardID: cardID,
            markupAmount: dec("2.2"),
            status: .provisional
        )

        let migratedAsUSD = legacyHKD.migratedLegacyEvidence(homeCurrency: "USD")

        XCTAssertNil(migratedAsUSD.settledAmount)
        XCTAssertNil(migratedAsUSD.originalAmount)
        XCTAssertNil(migratedAsUSD.repricingRateRequests)
    }

    func testLegacyMigrationRejectsChangedHomeCurrenciesWithSimilarRates() {
        let legacyCAD = ImportedTransaction(
            cardID: cardID,
            txDate: utcDate(2026, 4, 3),
            merchantName: "Near-rate legacy fixture",
            merchantCountry: "TH",
            billedCurrency: "THB",
            billedAmount: dec("100"),
            isForeign: true,
            isDccSuspected: false,
            homeCurrencyAmount: dec("4"),
            referenceRate: dec("0.04"), // bundled THB -> CAD
            effectiveRate: dec("0.04"),
            markupAmount: 0,
            confidence: .exact,
            provenance: ImportProvenance(
                sourceFilename: "legacy-cad.csv",
                importDate: utcDate(2026, 4, 4),
                parserConfidence: 1,
                mappingTemplateID: nil,
                fingerprint: "legacy-cad"
            ),
            calculationStatus: .provisional
        )

        let migratedAsSGD = legacyCAD.migratedLegacyEvidence(homeCurrency: "SGD")

        XCTAssertNil(migratedAsSGD.settledAmount)
        XCTAssertNil(migratedAsSGD.originalAmount)
        XCTAssertNil(migratedAsSGD.repricingRateRequests)
    }

    func testCurrencyScopeKeepsOneDatasetCurrencyAndRejectsMixedAppend() {
        let hkd = provisionalTransaction(
            settledAmount: dec("25"),
            settledCurrency: "HKD",
            originalAmount: dec("100"),
            originalCurrency: "THB",
            homeCurrency: "HKD"
        )
        let usd = provisionalTransaction(
            settledAmount: dec("4"),
            settledCurrency: "USD",
            originalAmount: dec("100"),
            originalCurrency: "THB",
            homeCurrency: "USD"
        )
        let legacy = summaryTransaction(cardID: cardID, markupAmount: dec("2.2"))

        XCTAssertEqual(
            ImportedTransactionCurrencyScope.canonicalHomeCurrency(in: [hkd, usd]),
            "HKD"
        )
        XCTAssertEqual(
            ImportedTransactionCurrencyScope.compatibleTransactions(
                in: [hkd, usd, legacy],
                homeCurrency: "HKD"
            ).map(\.id),
            [hkd.id, legacy.id]
        )
        XCTAssertTrue(ImportedTransactionCurrencyScope.canAppend([hkd], to: [hkd]))
        XCTAssertFalse(ImportedTransactionCurrencyScope.canAppend([usd], to: [hkd]))
    }

    func testVerifiedRepriceUsesPreservedStatementLegs() throws {
        let transaction = provisionalTransaction(
            settledAmount: dec("295"),
            settledCurrency: "HKD",
            originalAmount: dec("1240"),
            originalCurrency: "THB",
            homeCurrency: "HKD"
        )

        let updated = try XCTUnwrap(transaction.repriced(
            reference: verifiedTHBToHKD,
            settledToHome: nil
        ))

        XCTAssertEqual(updated.calculationStatus, .verified)
        XCTAssertEqual(updated.referenceRate, verifiedTHBToHKD.rate)
        XCTAssertEqual(updated.referenceRateSource, .ecb)
        XCTAssertEqual(
            updated.markupAmount,
            transaction.settledAmount! - transaction.originalAmount! * verifiedTHBToHKD.rate
        )
    }

    func testRepriceForeignSettlementRequiresAndUsesSecondQuote() throws {
        let transaction = provisionalTransaction(
            settledAmount: dec("50"),
            settledCurrency: "EUR",
            originalAmount: dec("55"),
            originalCurrency: "USD",
            homeCurrency: "HKD"
        )
        let usdToHKD = HistoricalRateQuote(
            request: HistoricalRateRequest(from: "USD", to: "HKD", day: "2026-04-03"),
            observationDay: "2026-04-02", rate: dec("7.80"), source: .ecb, status: .verified
        )
        let eurToHKD = HistoricalRateQuote(
            request: HistoricalRateRequest(from: "EUR", to: "HKD", day: "2026-04-03"),
            observationDay: "2026-04-02", rate: dec("8.50"), source: .ecb, status: .verified
        )

        XCTAssertNil(transaction.repriced(reference: usdToHKD, settledToHome: nil))

        let updated = try XCTUnwrap(transaction.repriced(
            reference: usdToHKD,
            settledToHome: eurToHKD
        ))
        XCTAssertEqual(updated.homeCurrencyAmount, dec("425"))
        XCTAssertEqual(updated.effectiveRate, dec("425") / dec("55"))
        XCTAssertEqual(updated.markupAmount, dec("425") - dec("55") * dec("7.80"))
        XCTAssertEqual(updated.calculationStatus, .verified)
    }

    func testPositiveLossTotalsDoNotLetSavingsHideLosses() {
        let cardA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let cardB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let transactions = [
            summaryTransaction(cardID: cardA, markupAmount: dec("-3")),
            summaryTransaction(cardID: cardA, markupAmount: dec("10")),
            summaryTransaction(cardID: cardB, markupAmount: dec("4.5")),
            summaryTransaction(cardID: cardB, markupAmount: nil),
        ]

        XCTAssertEqual(transactions.totalPositiveLoss, dec("14.5"))
        XCTAssertEqual(transactions.positiveLossByCard()[cardA], dec("10"))
        XCTAssertEqual(transactions.positiveLossByCard()[cardB], dec("4.5"))
    }

    func testVerifiedQuoteUpgradeTouchesOnlyReconstructableProvisionalRows() {
        let reconstructable = provisionalTransaction(
            settledAmount: dec("295"),
            settledCurrency: "HKD",
            originalAmount: dec("1240"),
            originalCurrency: "THB",
            homeCurrency: "HKD"
        )
        let legacy = summaryTransaction(
            cardID: cardID,
            markupAmount: dec("12.28"),
            status: .provisional
        )
        let alreadyVerified = summaryTransaction(
            cardID: cardID,
            markupAmount: dec("8"),
            status: .verified
        )
        let quotes = [verifiedTHBToHKD.request: verifiedTHBToHKD]

        let result = [reconstructable, legacy, alreadyVerified]
            .repricedProvisionalTransactions(using: quotes)

        XCTAssertEqual(result[0].resolvedCalculationStatus, .verified)
        XCTAssertEqual(result[0].referenceRate, verifiedTHBToHKD.rate)
        XCTAssertEqual(result[1], legacy)
        XCTAssertEqual(result[2], alreadyVerified)
    }

    private func provisionalTransaction(
        settledAmount: Decimal,
        settledCurrency: String,
        originalAmount: Decimal,
        originalCurrency: String,
        homeCurrency: String
    ) -> ImportedTransaction {
        ImportedTransaction(
            cardID: cardID,
            txDate: utcDate(2026, 4, 3),
            merchantName: "Merchant",
            merchantCountry: "??",
            billedCurrency: originalCurrency,
            billedAmount: originalAmount,
            isForeign: true,
            isDccSuspected: false,
            homeCurrencyAmount: settledAmount,
            referenceRate: dec("0.228"),
            effectiveRate: settledAmount / originalAmount,
            markupAmount: settledAmount - originalAmount * dec("0.228"),
            confidence: settledCurrency == homeCurrency ? .exact : .estimated,
            provenance: ImportProvenance(
                sourceFilename: "fixture.csv",
                importDate: utcDate(2026, 4, 4),
                parserConfidence: 1,
                mappingTemplateID: nil,
                fingerprint: "fixture-fingerprint"
            ),
            settledAmount: settledAmount,
            settledCurrency: settledCurrency,
            originalAmount: originalAmount,
            originalCurrency: originalCurrency,
            homeCurrencyAtImport: homeCurrency,
            referenceRateDate: utcDate(2026, 4, 3),
            referenceRateSource: .bundledFallback,
            calculationStatus: .provisional
        )
    }

    private func summaryTransaction(
        cardID: UUID,
        markupAmount: Decimal?,
        status: HistoricalCalculationStatus = .provisional
    ) -> ImportedTransaction {
        ImportedTransaction(
            cardID: cardID,
            txDate: utcDate(2026, 4, 3),
            merchantName: "Summary fixture",
            merchantCountry: "TH",
            billedCurrency: "THB",
            billedAmount: dec("100"),
            isForeign: true,
            isDccSuspected: false,
            homeCurrencyAmount: dec("25"),
            referenceRate: dec("0.228"),
            effectiveRate: dec("0.25"),
            markupAmount: markupAmount,
            confidence: .exact,
            provenance: ImportProvenance(
                sourceFilename: "summary.csv",
                importDate: utcDate(2026, 4, 4),
                parserConfidence: 1,
                mappingTemplateID: nil,
                fingerprint: UUID().uuidString
            ),
            calculationStatus: status
        )
    }
}
