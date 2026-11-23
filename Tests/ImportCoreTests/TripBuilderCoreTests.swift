import Foundation
import XCTest
@testable import ImportCore

final class TripBuilderCoreTests: XCTestCase {

    func testTwoForeignTxWithin48hStartsATrip() {
        let rows = [
            TripInputRow(date: utcDate(2026, 4, 2), currency: "THB", markup: dec("5")),
            TripInputRow(date: utcDate(2026, 4, 3), currency: "THB", markup: dec("3")),
        ]
        let trips = TripBuilderCore.build(rows: rows, asOf: utcDate(2026, 4, 3))
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].destinationCurrency, "THB")
        XCTAssertEqual(trips[0].destinationCountry, "TH")
    }

    func testLoneForeignTxNeverBecomesATrip() {
        let rows = [
            TripInputRow(date: utcDate(2026, 4, 2), currency: "THB", markup: dec("5")),
            TripInputRow(date: utcDate(2026, 4, 20), currency: "JPY", markup: dec("3")), // >48h later
        ]
        let trips = TripBuilderCore.build(rows: rows, asOf: utcDate(2026, 4, 21))
        XCTAssertEqual(trips.count, 0)
    }

    func testGapOverFiveDaysClosesTripAndStartsNewOne() {
        let rows = [
            TripInputRow(date: utcDate(2026, 4, 2), currency: "THB", markup: dec("5")),
            TripInputRow(date: utcDate(2026, 4, 3), currency: "THB", markup: dec("3")),
            // 10 days later -> quiet gap closes trip 1; needs a second tx within 48h to start trip 2
            TripInputRow(date: utcDate(2026, 4, 13), currency: "JPY", markup: dec("2")),
            TripInputRow(date: utcDate(2026, 4, 14), currency: "JPY", markup: dec("4")),
        ]
        let trips = TripBuilderCore.build(rows: rows, asOf: utcDate(2026, 4, 14))
        XCTAssertEqual(trips.count, 2)
        XCTAssertEqual(trips[0].destinationCurrency, "THB")
        XCTAssertNotNil(trips[0].endDate)
        XCTAssertEqual(trips[1].destinationCurrency, "JPY")
    }

    func testMultiLegClusterWithinFiveDayGapsIsOneSingleTrip() {
        let rows = [
            TripInputRow(date: utcDate(2025, 11, 20), currency: "JPY", markup: dec("7.91")),
            TripInputRow(date: utcDate(2025, 11, 21), currency: "JPY", markup: dec("4.48")),
            TripInputRow(date: utcDate(2025, 11, 23), currency: "JPY", markup: dec("8.04")), // 2-day gap, within 5
            TripInputRow(date: utcDate(2025, 11, 27), currency: "JPY", markup: dec("383.99")), // 4-day gap, within 5
        ]
        let trips = TripBuilderCore.build(rows: rows, asOf: utcDate(2025, 12, 10))
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].startDate, utcDate(2025, 11, 20))
        XCTAssertEqual(trips[0].endDate, utcDate(2025, 11, 27))
    }

    func testTotalMarkupSumsOnlyPositiveMarkups() {
        let rows = [
            TripInputRow(date: utcDate(2026, 4, 2), currency: "THB", markup: dec("10")),
            TripInputRow(date: utcDate(2026, 4, 3), currency: "THB", markup: dec("-4")), // excluded from total
            TripInputRow(date: utcDate(2026, 4, 4), currency: "THB", markup: nil), // unpriced, treated as 0
        ]
        let trips = TripBuilderCore.build(rows: rows, asOf: utcDate(2026, 4, 4))
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].totalMarkup, dec("10"))
    }

    func testFinalTripStaysOpenWhenAsOfIsWithinQuietWindow() {
        let rows = [
            TripInputRow(date: utcDate(2026, 6, 28), currency: "THB", markup: dec("2")),
            TripInputRow(date: utcDate(2026, 6, 29), currency: "THB", markup: dec("19")),
        ]
        let trips = TripBuilderCore.build(rows: rows, asOf: utcDate(2026, 6, 30))
        XCTAssertEqual(trips.count, 1)
        XCTAssertNil(trips[0].endDate)
    }

    func testFinalTripClosesWhenAsOfPastQuietWindow() {
        let rows = [
            TripInputRow(date: utcDate(2026, 6, 28), currency: "THB", markup: dec("2")),
            TripInputRow(date: utcDate(2026, 6, 29), currency: "THB", markup: dec("19")),
        ]
        let trips = TripBuilderCore.build(rows: rows, asOf: utcDate(2026, 7, 10))
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].endDate, utcDate(2026, 6, 29))
    }
}
