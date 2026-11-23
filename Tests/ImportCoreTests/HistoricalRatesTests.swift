import Foundation
import XCTest
@testable import ImportCore

final class HistoricalRatesTests: XCTestCase {
    private let sampleCSV = """
    KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
    EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-05,9.1185
    EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-05,37.987
    EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2026-06-05,1.164
    """

    func testParsesECBDataOnlyCSVAndComposesTHBToHKD() throws {
        let observations = try ECBRateCSVParser.parse(Data(sampleCSV.utf8))
        let book = HistoricalRateBook(observations: observations)
        let request = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-05")

        let quote = book.quote(for: request)

        XCTAssertEqual(observations.count, 3)
        XCTAssertEqual(quote?.source, .ecb)
        XCTAssertEqual(quote?.status, .verified)
        XCTAssertEqual(quote?.observationDay, "2026-06-05")
        XCTAssertEqual(
            quote?.rate,
            Decimal(string: "9.1185")! / Decimal(string: "37.987")!
        )
    }

    func testWeekendUsesNearestPreviousObservationOnly() throws {
        let observations = try ECBRateCSVParser.parse(Data(sampleCSV.utf8))
        let book = HistoricalRateBook(observations: observations)

        let quote = book.quote(for: HistoricalRateRequest(
            from: "USD", to: "HKD", day: "2026-06-07"
        ))

        XCTAssertEqual(quote?.observationDay, "2026-06-05")
        XCTAssertEqual(quote?.rate, Decimal(string: "9.1185")! / Decimal(string: "1.164")!)
    }

    func testDoesNotUseObservationAfterRequestedDay() throws {
        let observations = try ECBRateCSVParser.parse(Data(sampleCSV.utf8))
        let book = HistoricalRateBook(observations: observations)

        let quote = book.quote(for: HistoricalRateRequest(
            from: "USD", to: "HKD", day: "2026-06-04"
        ))

        XCTAssertNil(quote)
    }

    func testEURActsAsIdentitySideOfCrossRate() throws {
        let observations = try ECBRateCSVParser.parse(Data(sampleCSV.utf8))
        let book = HistoricalRateBook(observations: observations)

        let quote = book.quote(for: HistoricalRateRequest(
            from: "EUR", to: "HKD", day: "2026-06-05"
        ))

        XCTAssertEqual(quote?.rate, Decimal(string: "9.1185")!)
    }

    func testMalformedRowsDoNotDiscardValidObservations() throws {
        let mixed = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-05,9.1185
        EXR.D.USD.GBP.SP00.A,D,USD,GBP,SP00,A,2026-06-05,nope
        EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-05,37.987
        broken,row
        """

        let observations = try ECBRateCSVParser.parse(Data(mixed.utf8))

        XCTAssertEqual(observations.map(\.currency), ["HKD", "THB"])
    }

    func testBookSanitizesDuplicateAndNonpositiveCachedObservations() {
        let book = HistoricalRateBook(observations: [
            HistoricalRateObservation(currency: "HKD", day: "2026-06-05", unitsPerEUR: dec("9.1")),
            HistoricalRateObservation(currency: "HKD", day: "2026-06-05", unitsPerEUR: dec("9.2")),
            HistoricalRateObservation(currency: "THB", day: "2026-06-05", unitsPerEUR: dec("-37")),
            HistoricalRateObservation(currency: "TOO-LONG", day: "not-a-day", unitsPerEUR: dec("1")),
        ])

        XCTAssertEqual(book.observations.count, 1)
        XCTAssertEqual(book.observations.first?.unitsPerEUR, dec("9.2"))
        XCTAssertNil(book.quote(for: HistoricalRateRequest(
            from: "THB", to: "HKD", day: "2026-06-05"
        )))
    }

    func testBundledFallbackIsExplicitlyProvisional() {
        let request = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-05")

        let quote = RateTable.fallbackQuote(for: request)

        XCTAssertEqual(quote?.source, .bundledFallback)
        XCTAssertEqual(quote?.status, .provisional)
        XCTAssertEqual(quote?.observationDay, request.day)
        XCTAssertEqual(quote?.rate, RateTable.rate(from: "THB", to: "HKD"))
    }
}
