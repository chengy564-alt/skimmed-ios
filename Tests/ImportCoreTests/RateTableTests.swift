import Foundation
import XCTest
@testable import ImportCore

final class RateTableTests: XCTestCase {

    func testIdentityRateIsOne() {
        XCTAssertEqual(RateTable.rate(from: "HKD", to: "HKD"), 1)
    }

    func testRateComposesViaHKD() {
        // USD -> JPY should equal (USD->HKD) / (JPY->HKD), not a hardcoded direct pair.
        let usdToJpy = RateTable.rate(from: "USD", to: "JPY")
        let expected = RateTable.toHKD["USD"]! / RateTable.toHKD["JPY"]!
        XCTAssertEqual(usdToJpy, expected)
    }

    func testUnknownCurrencyReturnsNil() {
        XCTAssertNil(RateTable.rate(from: "XYZ", to: "HKD"))
        XCTAssertNil(RateTable.rate(from: "HKD", to: "XYZ"))
    }

    func testCurrencyCountryLookup() {
        XCTAssertEqual(CurrencyCountry.country(for: "THB"), "TH")
        XCTAssertEqual(CurrencyCountry.country(for: "JPY"), "JP")
        XCTAssertNil(CurrencyCountry.country(for: "XYZ"))
        XCTAssertEqual(CurrencyCountry.currency(forCountry: "TH"), "THB")
        XCTAssertEqual(CurrencyCountry.currency(forCountry: "ES"), "EUR")
        XCTAssertEqual(CurrencyCountry.currency(forCountry: "BS"), "BSD")
        XCTAssertEqual(CurrencyCountry.currency(forCountry: "BE"), "EUR")
        XCTAssertNil(CurrencyCountry.currency(forCountry: "XX"))
    }
}
