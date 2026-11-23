import XCTest
@testable import ImportCore

final class CSVImporterTests: XCTestCase {

    // MARK: - Auto-parse: full fixtures

    func testHSBCAutoParse() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("hsbc_hk"), filename: "hsbc_hk.csv")
        XCTAssertEqual(stmt.transactions.count, 4)

        let first = stmt.transactions[0]
        // "Transaction Date" outranks "Post Date" in the synonym table.
        XCTAssertEqual(first.date, utcDate(2026, 1, 1))
        XCTAssertEqual(first.description, "AMAZON JP TOKYO")
        // Money-out-negative export → spend flips positive.
        XCTAssertEqual(first.amount, dec("156.80"))
        XCTAssertEqual(first.originalAmount, dec("2900.00"))
        XCTAssertEqual(first.originalCurrency, "JPY")
        XCTAssertEqual(first.cardLast4, "1234")

        // Repayment (positive in the export) flips negative.
        XCTAssertEqual(stmt.transactions[3].amount, dec("-2500.00"))
        XCTAssertNil(stmt.transactions[3].originalAmount)

        XCTAssertEqual(stmt.statementCurrency, "HKD") // lifted from "Amount (HKD)"
        XCTAssertEqual(stmt.accountLast4, "1234")
        XCTAssertEqual(stmt.bankHint, "HSBC") // preamble line
        XCTAssertEqual(stmt.period, utcDate(2026, 1, 1)...utcDate(2026, 1, 19))
    }

    func testBarclaysDayFirstDates() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("barclays_uk"), filename: "barclays_uk.csv")
        XCTAssertEqual(stmt.transactions.count, 4)
        // 13/01 has day > 12 → whole column resolves as dd/MM/yyyy…
        XCTAssertEqual(stmt.transactions[0].date, utcDate(2026, 1, 13))
        // …so the ambiguous 02/02 and 05/02 rows land in February, not day 2 of month 5.
        XCTAssertEqual(stmt.transactions[2].date, utcDate(2026, 2, 2))
        // No ambiguity warning when the scan found evidence.
        XCTAssertFalse(stmt.warnings.contains { $0.contains("ambiguous") })
        XCTAssertEqual(stmt.bankHint, "Barclays") // filename fallback — no name in the body
    }

    func testChaseMonthFirstDates() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("chase_us"), filename: "chase_us.csv")
        XCTAssertEqual(stmt.transactions.count, 3)
        // 06/15 has second component > 12 → MM/dd/yyyy.
        XCTAssertEqual(stmt.transactions[0].date, utcDate(2026, 6, 15))
        XCTAssertEqual(stmt.transactions[2].date, utcDate(2026, 7, 1))
        XCTAssertEqual(stmt.transactions[0].amount, dec("23.40"))
        XCTAssertEqual(stmt.transactions[2].amount, dec("-500.00"))
    }

    func testEuropeanSemicolonDecimalCommaDotDates() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("european_semicolon"), filename: "export.csv")
        XCTAssertEqual(stmt.transactions.count, 3)
        XCTAssertEqual(stmt.transactions[0].date, utcDate(2026, 1, 15)) // dd.MM.yyyy
        XCTAssertEqual(stmt.transactions[0].amount, dec("45.60")) // -45,60 flipped
        XCTAssertEqual(stmt.transactions[1].amount, dec("1234.56")) // -1.234,56 → grouping dot stripped
        XCTAssertEqual(stmt.transactions[2].amount, dec("-2500.00")) // incoming 2.500,00 → negative
        XCTAssertEqual(stmt.statementCurrency, "EUR") // uniform Währung column
        XCTAssertNil(stmt.bankHint)
    }

    // MARK: - Encodings + delimiters

    func testUTF16Data() throws {
        let text = try Fixture.text("hsbc_hk")
        let utf16 = text.data(using: .utf16)! // BOM-prefixed, host byte order
        let stmt = try CSVImporter.parse(data: utf16, filename: "hsbc_hk.csv")
        XCTAssertEqual(stmt.transactions.count, 4)
        XCTAssertEqual(stmt.transactions[0].amount, dec("156.80"))
    }

    func testUTF8BOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(try Fixture.data("signed_single_column"))
        let stmt = try CSVImporter.parse(data: data, filename: "export.csv")
        XCTAssertEqual(stmt.transactions.count, 3)
        XCTAssertEqual(stmt.transactions[0].description, "BOOKSHOP AMSTERDAM")
    }

    func testTabDelimiter() throws {
        let csv = "Date\tDescription\tAmount\n2026-02-01\tKIOSK BERLIN\t-9.99\n2026-02-02\tBAKERY\t-3.50\n"
        let stmt = try CSVImporter.parse(data: Data(csv.utf8), filename: "export.tsv")
        XCTAssertEqual(stmt.transactions.count, 2)
        XCTAssertEqual(stmt.transactions[0].amount, dec("9.99"))
    }

    func testQuotedFieldContainingDelimiter() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("barclays_uk"), filename: "barclays_uk.csv")
        XCTAssertEqual(stmt.transactions[0].description, "TESCO STORES, LONDON")
        XCTAssertEqual(stmt.transactions[2].description, "PRET A MANGER, KINGS CROSS")
    }

    // MARK: - Dates: remaining formats + ambiguity default

    func testISODates() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("signed_single_column"), filename: "export.csv")
        XCTAssertEqual(stmt.transactions[0].date, utcDate(2026, 4, 1))
        XCTAssertEqual(stmt.period, utcDate(2026, 4, 1)...utcDate(2026, 4, 10))
    }

    func testAmbiguousSlashDatesDefaultToDayFirstWithWarning() throws {
        // All rows ≤ 12 in both positions → no evidence either way.
        let stmt = try CSVImporter.parse(data: Fixture.data("missing_original_currency"), filename: "export.csv")
        XCTAssertEqual(stmt.transactions[0].date, utcDate(2026, 5, 10)) // 10/05 read day-first
        XCTAssertTrue(stmt.warnings.contains { $0.contains("ambiguous") },
                      "expected an ambiguity warning, got \(stmt.warnings)")
    }

    func testExplicitDateFormatOverridesInference() throws {
        let csv = "When,What,How Much\n2026/03/07,SHOP,-5.00\n"
        let mapping = ColumnMapping(date: 0, description: 1, amount: 2, dateFormat: "yyyy/MM/dd")
        let stmt = try CSVImporter.parse(data: Data(csv.utf8), mapping: mapping)
        XCTAssertEqual(stmt.transactions[0].date, utcDate(2026, 3, 7))
    }

    // MARK: - Amount normalization

    func testSignedColumnNormalization() throws {
        // Export uses negatives → money out becomes positive spend, refund negative.
        let stmt = try CSVImporter.parse(data: Fixture.data("signed_single_column"), filename: "export.csv")
        XCTAssertEqual(stmt.transactions.map { $0.amount },
                       [dec("23.50"), dec("15.00"), dec("-23.50")])
    }

    func testAllPositiveSignedColumnTreatedAsSpend() throws {
        let csv = "Date,Description,Amount\n2026-01-01,SHOP A,12.00\n2026-01-02,SHOP B,8.50\n"
        let stmt = try CSVImporter.parse(data: Data(csv.utf8), filename: "export.csv")
        XCTAssertEqual(stmt.transactions.map { $0.amount }, [dec("12.00"), dec("8.50")])
    }

    func testDebitCreditNormalization() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("debit_credit_split"), filename: "export.csv")
        XCTAssertEqual(stmt.transactions.count, 3)
        // Debit column → positive spend; credit column → negative.
        XCTAssertEqual(stmt.transactions[0].amount, dec("45.60"))
        XCTAssertEqual(stmt.transactions[1].amount, dec("12.00"))
        XCTAssertEqual(stmt.transactions[2].amount, dec("-30.00"))
        // 13/03 row proves day-first here too.
        XCTAssertEqual(stmt.transactions[1].date, utcDate(2026, 3, 13))
    }

    func testMissingOriginalCurrency() throws {
        let stmt = try CSVImporter.parse(data: Fixture.data("missing_original_currency"), filename: "export.csv")
        XCTAssertEqual(stmt.transactions[0].originalAmount, dec("3800.00"))
        XCTAssertNil(stmt.transactions[0].originalCurrency)
        XCTAssertTrue(stmt.warnings.contains { $0.contains("Original amounts") },
                      "expected missing-currency warning, got \(stmt.warnings)")
    }

    func testLast4ExtractionVariants() throws {
        let csv = """
        Date,Description,Amount,Card Number
        2026-01-01,SHOP A,-5.00,**** 5678
        2026-01-02,SHOP B,-6.00,Card ending 5678
        """
        let stmt = try CSVImporter.parse(data: Data(csv.utf8), filename: "export.csv")
        XCTAssertEqual(stmt.transactions.map { $0.cardLast4 }, ["5678", "5678"])
        XCTAssertEqual(stmt.accountLast4, "5678")
    }

    // MARK: - Confidence gate + mapping path

    func testUnknownHeadersThrowNeedsMapping() throws {
        XCTAssertThrowsError(try CSVImporter.parse(data: Fixture.data("unknown_bank"),
                                                   filename: "unknown_bank.csv")) { error in
            guard case let ImportError.needsMapping(headers, sampleRows) = error else {
                return XCTFail("expected .needsMapping, got \(error)")
            }
            XCTAssertEqual(headers, ["Col1", "Col2", "Col3", "Col4"])
            XCTAssertEqual(sampleRows.count, 3)
            XCTAssertEqual(sampleRows[0][1], "GROCERY MART")
        }
    }

    func testColumnMappingDrivenParse() throws {
        let mapping = ColumnMapping(date: 0, description: 1, amount: 2)
        let stmt = try CSVImporter.parse(data: Fixture.data("unknown_bank"), mapping: mapping)
        XCTAssertEqual(stmt.transactions.count, 3)
        XCTAssertEqual(stmt.transactions[0].date, utcDate(2026, 1, 5))
        XCTAssertEqual(stmt.transactions[0].description, "GROCERY MART")
        XCTAssertEqual(stmt.transactions[0].amount, dec("12.30"))
    }

    func testHeadersFunctionSkipsPreamble() throws {
        let (headers, sampleRows) = try CSVImporter.headers(data: Fixture.data("hsbc_hk"))
        XCTAssertEqual(headers.first, "Post Date")
        XCTAssertEqual(headers.count, 7)
        XCTAssertEqual(sampleRows.count, 4)
        XCTAssertEqual(sampleRows[0][2], "AMAZON JP TOKYO")
    }

    // MARK: - Failure modes

    func testEmptyDataThrowsEmpty() {
        XCTAssertThrowsError(try CSVImporter.parse(data: Data(), filename: "empty.csv")) {
            XCTAssertEqual($0 as? ImportError, .empty)
        }
    }

    func testHeaderOnlyThrowsEmpty() {
        let csv = "Date,Description,Amount\n"
        XCTAssertThrowsError(try CSVImporter.parse(data: Data(csv.utf8), filename: "export.csv")) {
            XCTAssertEqual($0 as? ImportError, .empty)
        }
    }

    func testBinaryGarbageThrowsUnreadable() {
        let junk = Data([UInt8](repeating: 0x01, count: 64) + [UInt8](repeating: 0x02, count: 64))
        XCTAssertThrowsError(try CSVImporter.parse(data: junk, filename: "scan.csv")) {
            XCTAssertEqual($0 as? ImportError, .unreadable)
        }
    }
}
