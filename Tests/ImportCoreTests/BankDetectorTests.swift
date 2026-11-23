import XCTest
@testable import ImportCore

final class BankDetectorTests: XCTestCase {

    func testFilenameDetectionIsHighConfidence() throws {
        let cases: [(fixture: String, filename: String, bank: String)] = [
            ("hsbc_hk", "hsbc_hk.csv", "HSBC"),
            ("barclays_uk", "barclays_uk.csv", "Barclays"),
            ("chase_us", "chase_us.csv", "Chase"),
        ]
        for c in cases {
            let stmt = try CSVImporter.parse(data: Fixture.data(c.fixture), filename: c.filename)
            let guess = BankDetector.detect(filename: c.filename, statement: stmt, rawText: nil)
            XCTAssertEqual(guess?.name, c.bank)
            XCTAssertGreaterThanOrEqual(guess?.confidence ?? 0, 0.85, "\(c.bank) via filename")
        }
    }

    func testHeaderSignatureDetectionWithNeutralFilename() throws {
        // No bank token in filename or (for Barclays/Chase) in the body —
        // the column-signature fingerprint has to carry it.
        let cases: [(fixture: String, bank: String)] = [
            ("hsbc_hk", "HSBC"), // body name + "Amount (HKD)" signature
            ("barclays_uk", "Barclays"), // Number/Account/Subcategory/Memo signature
            ("chase_us", "Chase"), // Transaction Date/Post Date/Category/Type signature
        ]
        for c in cases {
            let text = try Fixture.text(c.fixture)
            let stmt = try CSVImporter.parse(data: Fixture.data(c.fixture), filename: "statement.csv")
            let guess = BankDetector.detect(filename: "statement.csv", statement: stmt, rawText: text)
            XCTAssertEqual(guess?.name, c.bank)
            XCTAssertGreaterThanOrEqual(guess?.confidence ?? 0, 0.6, "\(c.bank) via headers/content")
        }
    }

    func testUnknownBankReturnsNil() throws {
        let mapping = ColumnMapping(date: 0, description: 1, amount: 2)
        let stmt = try CSVImporter.parse(data: Fixture.data("unknown_bank"), mapping: mapping)
        let guess = BankDetector.detect(filename: "statement.csv", statement: stmt,
                                        rawText: try Fixture.text("unknown_bank"))
        XCTAssertNil(guess)
    }

    func testBICPatternDetection() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("signed_single_column"),
                                         filename: "statement.csv")
        let raw = "Statement for account GB29 0000 0000, BIC BARCGB22\n" + (try Fixture.text("signed_single_column"))
        let guess = BankDetector.detect(filename: "statement.csv", statement: stmt, rawText: raw)
        XCTAssertEqual(guess?.name, "Barclays")
        XCTAssertGreaterThanOrEqual(guess?.confidence ?? 0, 0.8)
    }
}
