import Foundation
import XCTest
@testable import ImportCore

final class AnalyzerCoreTests: XCTestCase {

    private func tx(
        date: Date = utcDate(2026, 4, 3),
        description: String = "Merchant",
        amount: Decimal,
        currency: String? = "HKD",
        originalAmount: Decimal? = nil,
        originalCurrency: String? = nil
    ) -> ParsedTransaction {
        ParsedTransaction(
            date: date, description: description, amount: amount, currency: currency,
            originalAmount: originalAmount, originalCurrency: originalCurrency,
            cardLast4: nil, rawLine: description
        )
    }

    func testDomesticRowIsExactAndNotForeign() {
        let row = AnalyzerCore.classify(
            tx: tx(amount: dec("100.00"), currency: "HKD"),
            fingerprint: "fp1", homeCurrency: "HKD"
        )
        XCTAssertFalse(row.isForeign)
        XCTAssertFalse(row.isDccSuspected)
        XCTAssertEqual(row.confidence, .exact)
        XCTAssertNil(row.markupAmount)
    }

    func testForeignRowWithBothLegsIsExact() {
        // Settled HKD 110.14 against original SGD 18.6 — both legs present.
        let row = AnalyzerCore.classify(
            tx: tx(amount: dec("110.14"), currency: "HKD",
                   originalAmount: dec("18.6"), originalCurrency: "SGD"),
            fingerprint: "fp2", homeCurrency: "HKD"
        )
        XCTAssertTrue(row.isForeign)
        XCTAssertFalse(row.isDccSuspected)
        XCTAssertEqual(row.confidence, .exact)
        XCTAssertEqual(row.billedCurrency, "SGD")
        XCTAssertEqual(row.billedAmount, dec("18.6"))
        XCTAssertNotNil(row.markupAmount)
        // effectiveRate = 110.14 / 18.6, referenceRate from bundled table (5.78)
        let expectedEffective = dec("110.14") / dec("18.6")
        XCTAssertEqual(row.effectiveRate, expectedEffective)
        let expectedMarkup = dec("110.14") - dec("18.6") * dec("5.78")
        XCTAssertEqual(row.markupAmount, expectedMarkup)
    }

    func testExplicitDailyRateOverridesBundledSnapshot() {
        let quote = HistoricalRateQuote(
            request: HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-04-03"),
            observationDay: "2026-04-02",
            rate: dec("0.230"),
            source: .ecb,
            status: .verified
        )
        let context = TransactionRateContext(reference: quote, settledToHome: nil)

        let row = AnalyzerCore.classify(
            tx: tx(amount: dec("295"), currency: "HKD",
                   originalAmount: dec("1240"), originalCurrency: "THB"),
            fingerprint: "fp-daily",
            homeCurrency: "HKD",
            rateContext: context
        )

        XCTAssertEqual(row.referenceRate, quote.rate)
        XCTAssertEqual(row.referenceRateQuote?.source, .ecb)
        XCTAssertEqual(row.referenceRateQuote?.observationDay, "2026-04-02")
        XCTAssertEqual(row.markupAmount, dec("295") - dec("1240") * quote.rate)
    }

    func testDccIsNeverGuessedEvenWithSettledHomeAndForeignOriginal() {
        // Settled in home currency (HKD) with a foreign original also printed is the shape
        // transparent banks use for perfectly normal FX (see AnalyzerCore.classify's doc
        // comment) — v1 never flags this shape as DCC since there's no merchant-country
        // signal to honestly confirm it.
        let row = AnalyzerCore.classify(
            tx: tx(amount: dec("428.50"), currency: "HKD",
                   originalAmount: dec("1760.00"), originalCurrency: "THB"),
            fingerprint: "fp3", homeCurrency: "HKD"
        )
        XCTAssertTrue(row.isForeign)
        XCTAssertFalse(row.isDccSuspected)
        XCTAssertEqual(row.confidence, .exact)
        XCTAssertEqual(row.billedCurrency, "THB")
        XCTAssertEqual(row.billedAmount, dec("1760.00"))
    }

    func testForeignCurrencyDenominatedSettledLegIsEstimated() {
        // Both legs present, but the settled leg itself isn't home currency (e.g. a
        // foreign-currency wallet card) — converting it needs the bundled table, so the
        // home-currency figure is rate-derived, not statement-stated -> estimated.
        let row = AnalyzerCore.classify(
            tx: tx(amount: dec("50.00"), currency: "EUR",
                   originalAmount: dec("55.00"), originalCurrency: "USD"),
            fingerprint: "fp3b", homeCurrency: "HKD"
        )
        XCTAssertTrue(row.isForeign)
        XCTAssertFalse(row.isDccSuspected)
        XCTAssertEqual(row.confidence, .estimated)
        XCTAssertNotNil(row.markupAmount)
    }

    func testForeignSettledCurrencyWithNoOriginalIsUnableToCalculate() {
        // Row is in a foreign currency but there's no original amount to compare it to.
        let row = AnalyzerCore.classify(
            tx: tx(amount: dec("50.00"), currency: "USD"),
            fingerprint: "fp4", homeCurrency: "HKD"
        )
        XCTAssertTrue(row.isForeign)
        XCTAssertFalse(row.isDccSuspected)
        XCTAssertEqual(row.confidence, .unableToCalculate)
        XCTAssertNil(row.markupAmount)
        XCTAssertNil(row.effectiveRate)
    }

    func testOffTableSettledCurrencyCollapsesToUnableToCalculate() {
        // Original leg is on-table (JPY) but the settled leg is an off-table
        // currency — converting it is impossible, so no markup may be
        // fabricated from the raw unconverted figure.
        let row = AnalyzerCore.classify(
            tx: tx(amount: dec("120.00"), currency: "XXX",
                   originalAmount: dec("6480"), originalCurrency: "JPY"),
            fingerprint: "fp-offtable", homeCurrency: "HKD"
        )
        XCTAssertTrue(row.isForeign)
        XCTAssertEqual(row.confidence, .unableToCalculate)
        XCTAssertNil(row.markupAmount)
        XCTAssertNil(row.effectiveRate)
    }

    func testNoDccGuessedFromDomesticRowAlone() {
        // No foreign evidence at all -> never DCC, even though settled currency == home.
        let row = AnalyzerCore.classify(
            tx: tx(amount: dec("30.00"), currency: "HKD"),
            fingerprint: "fp5", homeCurrency: "HKD"
        )
        XCTAssertFalse(row.isDccSuspected)
        XCTAssertFalse(row.isForeign)
    }

    func testNegativeMarkupIsKeptSignedNotClamped() {
        // effectiveRate below the reference rate -> a real negative markup (better than mid-market).
        let row = AnalyzerCore.classify(
            tx: tx(amount: dec("100.00"), currency: "HKD",
                   originalAmount: dec("20.00"), originalCurrency: "USD"),
            fingerprint: "fp6", homeCurrency: "HKD"
        )
        // effectiveRate = 100/20 = 5.0, reference = 7.80 -> markup = (5.0 - 7.8) * 20 = -56
        XCTAssertEqual(row.markupAmount, dec("-56"))
        XCTAssertTrue((row.markupAmount ?? 0) < 0)
    }

    func testZeroOriginalAmountIsUnableToCalculate() {
        let row = AnalyzerCore.classify(
            tx: tx(
                amount: dec("100"), currency: "HKD",
                originalAmount: 0, originalCurrency: "THB"
            ),
            fingerprint: "fp-zero-original",
            homeCurrency: "HKD"
        )

        XCTAssertTrue(row.isForeign)
        XCTAssertEqual(row.confidence, .unableToCalculate)
        XCTAssertNil(row.effectiveRate)
        XCTAssertNil(row.markupAmount)
    }

    func testDedupSkipsExistingFingerprintsAndCountsThem() {
        let t1 = tx(description: "Coffee", amount: dec("10"), currency: "HKD")
        let t2 = tx(description: "Lunch", amount: dec("20"), currency: "HKD")
        let fp1 = Fingerprint.make(cardID: "card1", tx: t1)
        let (rows, duplicates) = AnalyzerCore.analyze(
            transactions: [t1, t2], cardID: "card1", homeCurrency: "HKD",
            existingFingerprints: [fp1]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(duplicates, 1)
        XCTAssertEqual(rows.first?.tx.description, "Lunch")
    }

    func testAnalyzeProducesNoDuplicatesWhenFingerprintSetEmpty() {
        let t1 = tx(description: "Coffee", amount: dec("10"), currency: "HKD")
        let (rows, duplicates) = AnalyzerCore.analyze(
            transactions: [t1], cardID: "card1", homeCurrency: "HKD",
            existingFingerprints: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(duplicates, 0)
    }
}

extension AnalyzerCoreTests {
    /// Regression: a misparsed row (an account/reference number captured as
    /// the original amount) must never produce a markup — the implied rate
    /// is wildly off reference, so the row collapses to unableToCalculate.
    func testImplausibleImpliedRateCollapsesToUnableToCalculate() {
        let tx = ParsedTransaction(
            date: Date(), description: "MISPARSED ROW",
            amount: 350, currency: "HKD",
            originalAmount: 106_054_966, originalCurrency: "CNY",
            cardLast4: nil, rawLine: ""
        )
        let row = AnalyzerCore.classify(tx: tx, fingerprint: "f1", homeCurrency: "HKD")
        XCTAssertEqual(row.confidence, .unableToCalculate)
        XCTAssertNil(row.markupAmount)
        XCTAssertTrue(row.isForeign)
    }

    /// A realistic DCC-ish row (a few percent over reference) keeps its
    /// exact confidence and small markup — the guard must not catch it.
    func testPlausibleMarkupSurvivesTheGuard() {
        // THB→HKD reference 0.228; bill 1240 THB settled at 295 HKD implies
        // 0.2379 (~4.3% over reference) — a normal bad rate, not a misparse.
        let tx = ParsedTransaction(
            date: Date(), description: "THIP SAMAI",
            amount: 295, currency: "HKD",
            originalAmount: 1240, originalCurrency: "THB",
            cardLast4: nil, rawLine: ""
        )
        let row = AnalyzerCore.classify(tx: tx, fingerprint: "f2", homeCurrency: "HKD")
        XCTAssertEqual(row.confidence, .exact)
        XCTAssertNotNil(row.markupAmount)
        XCTAssertGreaterThan(row.markupAmount!, 0)
    }

    func testRefundWithBothStatementLegsKeepsCalculableEvidence() {
        let refund = ParsedTransaction(
            date: Date(), description: "THIP SAMAI REFUND",
            amount: dec("-295"), currency: "HKD",
            originalAmount: dec("-1240"), originalCurrency: "THB",
            cardLast4: nil, rawLine: ""
        )

        let row = AnalyzerCore.classify(
            tx: refund,
            fingerprint: "refund",
            homeCurrency: "HKD"
        )

        XCTAssertEqual(row.confidence, .exact)
        XCTAssertNotNil(row.effectiveRate)
        XCTAssertNotNil(row.markupAmount)
    }
}
