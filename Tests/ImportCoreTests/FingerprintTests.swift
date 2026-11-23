import XCTest
@testable import ImportCore

final class FingerprintTests: XCTestCase {

    private func tx(date: Date = utcDate(2026, 6, 1), description: String = "CAFE MILANO",
                    amount: Decimal = dec("8.50"), currency: String? = "EUR") -> ParsedTransaction {
        ParsedTransaction(date: date, description: description, amount: amount, currency: currency,
                          originalAmount: nil, originalCurrency: nil, cardLast4: nil, rawLine: "")
    }

    func testStableAcrossCalls() {
        let a = Fingerprint.make(cardID: "card-1", tx: tx())
        let b = Fingerprint.make(cardID: "card-1", tx: tx())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 16) // fnv-1a 64 as hex
    }

    func testDescriptionWhitespaceAndCaseNormalized() {
        let a = Fingerprint.make(cardID: "card-1", tx: tx(description: "CAFE   MILANO"))
        let b = Fingerprint.make(cardID: "card-1", tx: tx(description: "cafe milano"))
        XCTAssertEqual(a, b)
    }

    func testDiffersByEachField() {
        let base = Fingerprint.make(cardID: "card-1", tx: tx())
        XCTAssertNotEqual(base, Fingerprint.make(cardID: "card-1", tx: tx(amount: dec("8.51"))))
        XCTAssertNotEqual(base, Fingerprint.make(cardID: "card-1", tx: tx(date: utcDate(2026, 6, 2))))
        XCTAssertNotEqual(base, Fingerprint.make(cardID: "card-1", tx: tx(description: "CAFE ROMA")))
        XCTAssertNotEqual(base, Fingerprint.make(cardID: "card-2", tx: tx()))
    }

    func testDuplicatesFixtureCollapses() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("duplicates"), filename: "duplicates.csv")
        XCTAssertEqual(stmt.transactions.count, 3)
        let prints = Set(stmt.transactions.map { Fingerprint.make(cardID: "card-1", tx: $0) })
        XCTAssertEqual(prints.count, 2) // the two identical CAFE MILANO rows collide
    }
}
