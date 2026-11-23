import XCTest
import CoreGraphics
import CoreText
@testable import ImportCore

/// PDF fixtures are generated in code at test time — a Core Graphics PDF
/// context drawing real CTLine text — so the repo carries no binary fixture
/// and the text layer PDFKit extracts is exactly what we drew.
final class PDFStatementImporterTests: XCTestCase {

    // MARK: - Fixture generation

    /// One-page, text-searchable PDF: each string is drawn as its own line.
    /// Pass an empty array for a valid PDF with no text layer (a "scan").
    private func makePDF(lines: [String]) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        var y: CGFloat = 760
        for line in lines {
            let attributed = NSAttributedString(
                string: line,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(ctLine, context)
            y -= 14
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A statement-shaped fixture: bank + period + card + currency header,
    /// a column caption line, five good rows (incl. CR credit and two foreign
    /// originals), one date-led line with no amount, and a footer.
    private var statementLines: [String] {
        [
            "HSBC Premier Mastercard",
            "Statement period 01 Jun 2026 to 30 Jun 2026",
            "Card ending 5566",
            "All amounts in HKD unless stated otherwise",
            "Date Description Amount",
            "02 Jun 2026 STARBUCKS CENTRAL HONG KONG 48.00",
            "05 Jun 2026 AMAZON.CO.JP TOKYO JPY 12,300 678.45",
            "12 Jun 2026 PAYMENT RECEIVED - THANK YOU 5,000.00 CR",
            "18 Jun 2026 AIRBNB LONDON GBP 210.40 2,105.33",
            "19 Jun 2026 FEE ADJUSTMENT SEE NOTE 3", // date-led, no amount → warning
            "25 Jun 2026 WELLCOME SUPERMARKET NORTH POINT 312.90",
            "Page 1 of 1",
        ]
    }

    // MARK: - (1) Known rows parse exactly

    func testParsesKnownRowsExactly() throws {
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: statementLines),
                                                  filename: "statement_jun.pdf")
        XCTAssertEqual(stmt.transactions.count, 5)

        let t0 = stmt.transactions[0]
        XCTAssertEqual(t0.date, utcDate(2026, 6, 2))
        XCTAssertEqual(t0.description, "STARBUCKS CENTRAL HONG KONG")
        XCTAssertEqual(t0.amount, dec("48.00")) // spend-positive
        XCTAssertNil(t0.originalAmount)

        // Foreign original mined out of the description (JPY: no decimals).
        let t1 = stmt.transactions[1]
        XCTAssertEqual(t1.date, utcDate(2026, 6, 5))
        XCTAssertEqual(t1.description, "AMAZON.CO.JP TOKYO")
        XCTAssertEqual(t1.amount, dec("678.45"))
        XCTAssertEqual(t1.originalAmount, dec("12300"))
        XCTAssertEqual(t1.originalCurrency, "JPY")

        // CR marker → money in → negative, and the original inherits the sign rule.
        let t2 = stmt.transactions[2]
        XCTAssertEqual(t2.date, utcDate(2026, 6, 12))
        XCTAssertEqual(t2.amount, dec("-5000.00"))
        XCTAssertEqual(t2.description, "PAYMENT RECEIVED - THANK YOU")

        // Foreign original WITH decimals uses the document's decimal mode.
        let t3 = stmt.transactions[3]
        XCTAssertEqual(t3.description, "AIRBNB LONDON")
        XCTAssertEqual(t3.amount, dec("2105.33"))
        XCTAssertEqual(t3.originalAmount, dec("210.40"))
        XCTAssertEqual(t3.originalCurrency, "GBP")

        let t4 = stmt.transactions[4]
        XCTAssertEqual(t4.date, utcDate(2026, 6, 25))
        XCTAssertEqual(t4.amount, dec("312.90"))
    }

    // MARK: - (2) Header metadata

    func testHeaderMetadataExtracted() throws {
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: statementLines),
                                                  filename: "statement_jun.pdf")
        XCTAssertEqual(stmt.bankHint, "HSBC") // BankDetector normalization path
        XCTAssertEqual(stmt.accountLast4, "5566")
        XCTAssertEqual(stmt.statementCurrency, "HKD")
        // Explicit header period wins over the tx min…max (2 Jun…25 Jun).
        XCTAssertEqual(stmt.period, utcDate(2026, 6, 1)...utcDate(2026, 6, 30))
    }

    func testPeriodFallsBackToTransactionDates() throws {
        let lines = [
            "Monzo",
            "03/06/2026 GREGGS MANCHESTER 4.20",
            "15/06/2026 TESCO EXPRESS LONDON 18.75",
        ]
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: lines), filename: "x.pdf")
        XCTAssertEqual(stmt.period, utcDate(2026, 6, 3)...utcDate(2026, 6, 15))
        XCTAssertEqual(stmt.bankHint, "Monzo")
        XCTAssertNil(stmt.accountLast4)
    }

    // MARK: - (3) No text layer / not a statement

    func testBlankPDFThrowsUnreadable() {
        // Valid PDF, one page, nothing drawn — the "scanned document" shape.
        let data = makePDF(lines: [])
        XCTAssertThrowsError(try PDFStatementImporter.parse(data: data, filename: "scan.pdf")) {
            XCTAssertEqual($0 as? ImportError, .unreadable)
        }
    }

    func testGarbageDataThrowsUnreadable() {
        let data = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x42])
        XCTAssertThrowsError(try PDFStatementImporter.parse(data: data, filename: "junk.pdf")) {
            XCTAssertEqual($0 as? ImportError, .unreadable)
        }
    }

    func testTextButNoTransactionsThrowsEmpty() {
        // Extractable text, zero transaction-shaped lines → .empty, not .unreadable.
        let data = makePDF(lines: ["HSBC Premier Mastercard", "Thank you for banking with us"])
        XCTAssertThrowsError(try PDFStatementImporter.parse(data: data, filename: "letter.pdf")) {
            XCTAssertEqual($0 as? ImportError, .empty)
        }
    }

    // MARK: - (4) Malformed lines are warnings, never rows

    func testMalformedLinesLandInWarningsNotTransactions() throws {
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: statementLines),
                                                  filename: "statement_jun.pdf")
        // The date-led no-amount line was skipped with a warning…
        XCTAssertTrue(stmt.warnings.contains { $0.contains("FEE ADJUSTMENT") })
        // …and never became a transaction.
        XCTAssertFalse(stmt.transactions.contains { $0.description.contains("FEE ADJUSTMENT") })
        // Non-date furniture (captions, footers) is ignored silently, not a doubt.
        XCTAssertFalse(stmt.warnings.contains { $0.contains("Page 1 of 1") })
        XCTAssertFalse(stmt.warnings.contains { $0.contains("Date Description Amount") })
    }

    // MARK: - Decimal-comma documents

    // MARK: - Balance/total footer rows are warnings, never transactions

    func testBalanceFooterLinesLandInWarningsNotTransactions() throws {
        let lines = [
            "HSBC Premier Mastercard",
            "01 Jun 2026 OPENING BALANCE BROUGHT FORWARD 8,000.00",
            "02 Jun 2026 STARBUCKS CENTRAL HONG KONG 48.00",
            "25 Jun 2026 WELLCOME SUPERMARKET NORTH POINT 312.90",
            "30 Jun 2026 CLOSING BALANCE 12,345.67",
        ]
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: lines), filename: "bal.pdf")

        XCTAssertEqual(stmt.transactions.count, 2)
        XCTAssertTrue(stmt.transactions.contains { $0.description.contains("STARBUCKS") })
        XCTAssertTrue(stmt.transactions.contains { $0.description.contains("WELLCOME") })

        XCTAssertFalse(stmt.transactions.contains { $0.description.localizedCaseInsensitiveContains("balance") })
        XCTAssertTrue(stmt.warnings.contains { $0.contains("OPENING BALANCE BROUGHT FORWARD") })
        XCTAssertTrue(stmt.warnings.contains { $0.contains("CLOSING BALANCE") })
    }

    // MARK: - Running-balance layouts never capture the balance column

    func testRunningBalanceLineIsWarningNotTransaction() throws {
        let lines = [
            "HSBC Premier Mastercard",
            "02 Jun 2026 STARBUCKS CENTRAL 48.00 1,282.45",
            "05 Jun 2026 WELLCOME SUPERMARKET 90.10",
        ]
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: lines), filename: "rb.pdf")

        XCTAssertEqual(stmt.transactions.count, 1)
        XCTAssertEqual(stmt.transactions[0].description, "WELLCOME SUPERMARKET")
        XCTAssertFalse(stmt.transactions.contains { $0.description.contains("STARBUCKS") })
        XCTAssertTrue(stmt.warnings.contains { $0.contains("STARBUCKS CENTRAL 48.00 1,282.45") })
    }

    // MARK: - Lowercase "Cr" credit marker

    func testLowercaseCrCreditParsesAsNegativeAmount() throws {
        let lines = [
            "HSBC Premier Mastercard",
            "12 Jun 2026 PAYMENT RECEIVED - THANK YOU 5,000.00 Cr",
        ]
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: lines), filename: "cr.pdf")

        XCTAssertEqual(stmt.transactions.count, 1)
        XCTAssertEqual(stmt.transactions[0].amount, dec("-5000.00")) // credit → negative
        XCTAssertEqual(stmt.transactions[0].description, "PAYMENT RECEIVED - THANK YOU")
    }

    func testCommaDecimalEuropeanStatement() throws {
        let lines = [
            "Kontoauszug", // no known bank on purpose
            "12.06.2026 CAFE EINSTEIN BERLIN 1.234,56",
            "14.06.2026 DB BAHN MUENCHEN 45,60",
        ]
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: lines), filename: "konto.pdf")
        XCTAssertEqual(stmt.transactions.count, 2)
        XCTAssertEqual(stmt.transactions[0].date, utcDate(2026, 6, 12))
        XCTAssertEqual(stmt.transactions[0].amount, dec("1234.56"))
        XCTAssertEqual(stmt.transactions[1].amount, dec("45.60"))
        XCTAssertNil(stmt.bankHint)
    }

    // MARK: - Multi-line record mining (the real-world shape this file exists to fix)

    /// A synthetic statement in the shape that broke the old single-line
    /// miner: date-led lines with NO amount, the amount arriving one or two
    /// lines later; several transactions sharing one printed date (only the
    /// first repeats the date; the rest lead with the "VIS"/"CR" transaction-
    /// type code instead); a ")))" contactless-icon continuation line inside
    /// a record; a Paid out/Paid in/Balance column header; and brought-
    /// forward/carried-forward rows that must never leak through as spend.
    /// Every merchant/amount here is invented — no real statement data.
    private var multiLineLedgerLines: [String] {
        [
            "Monzo",
            "Statement period 01 Jun 2026 to 30 Jun 2026",
            "Card ending 9911",
            "Date Description Paid out Paid in Balance",
            "01 Jun 26 BALANCE BROUGHT FORWARD",
            "100.00",
            "02 Jun 26 VIS GENERAL STORE",
            "CityTown 15.50 84.50",
            "03 Jun 26 VIS COFFEE HOUSE",
            "))) Roastery",
            "Downtown 4.25 80.25",
            "05 Jun 26 CR 1/J SMITH",
            "SALARY 500.00 580.25",
            "10 Jun 26 VIS BOOKSHOP",
            "Riverside 9.00",
            "VIS MUSIC STORE",
            "Riverside 12.00 559.25",
            "30 Jun 26 BALANCE CARRIED FORWARD",
            "559.25",
        ]
    }

    func testMultiLineRecordsParseExactRowsAndAmounts() throws {
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: multiLineLedgerLines),
                                                  filename: "ledger.pdf")
        XCTAssertEqual(stmt.transactions.count, 5)

        // Date-led line carried no amount; it arrived on the very next line.
        let t0 = stmt.transactions[0]
        XCTAssertEqual(t0.date, utcDate(2026, 6, 2))
        XCTAssertEqual(t0.description, "VIS GENERAL STORE CityTown")
        XCTAssertEqual(t0.amount, dec("15.50")) // spend-positive; balance (84.50) dropped

        // ")))" contactless-icon continuation line is stripped as noise, not
        // left in the description; the record still spans 3 physical lines.
        let t1 = stmt.transactions[1]
        XCTAssertEqual(t1.date, utcDate(2026, 6, 3))
        XCTAssertEqual(t1.description, "VIS COFFEE HOUSE Roastery Downtown")
        XCTAssertEqual(t1.amount, dec("4.25"))

        // Leading "CR" transaction-type code (not a trailing CR/DR amount
        // marker) is the credit signal — resolved confidently, no warning.
        let t2 = stmt.transactions[2]
        XCTAssertEqual(t2.date, utcDate(2026, 6, 5))
        XCTAssertEqual(t2.description, "CR 1/J SMITH SALARY")
        XCTAssertEqual(t2.amount, dec("-500.00")) // paid in

        // Two undated transactions share the "10 Jun 26" date — only the
        // first repeats it; "VIS MUSIC STORE" has no date of its own.
        let t3 = stmt.transactions[3]
        XCTAssertEqual(t3.date, utcDate(2026, 6, 10))
        XCTAssertEqual(t3.description, "VIS BOOKSHOP Riverside")
        XCTAssertEqual(t3.amount, dec("9.00"))

        let t4 = stmt.transactions[4]
        XCTAssertEqual(t4.date, utcDate(2026, 6, 10))
        XCTAssertEqual(t4.description, "VIS MUSIC STORE Riverside")
        XCTAssertEqual(t4.amount, dec("12.00"))
    }

    func testMultiLineBroughtAndCarriedForwardRowsAreExcluded() throws {
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: multiLineLedgerLines),
                                                  filename: "ledger.pdf")
        XCTAssertFalse(stmt.transactions.contains { $0.amount == dec("100.00") })
        XCTAssertFalse(stmt.transactions.contains { $0.amount == dec("559.25") })
        XCTAssertFalse(stmt.transactions.contains { $0.description.localizedCaseInsensitiveContains("balance") })
        XCTAssertTrue(stmt.warnings.contains { $0.contains("BALANCE BROUGHT FORWARD") })
        XCTAssertTrue(stmt.warnings.contains { $0.contains("BALANCE CARRIED FORWARD") })

        // No genuinely ambiguous paid-in/out records here (every leading
        // token is a recognised VIS/CR marker) — no ambiguity warnings.
        XCTAssertFalse(stmt.warnings.contains { $0.contains("Assumed paid out") })
    }

    func testMultiLineHeaderMetadata() throws {
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: multiLineLedgerLines),
                                                  filename: "ledger.pdf")
        XCTAssertEqual(stmt.bankHint, "Monzo")
        XCTAssertEqual(stmt.accountLast4, "9911")
        XCTAssertEqual(stmt.period, utcDate(2026, 6, 1)...utcDate(2026, 6, 30))
    }

    // MARK: - Foreign ORIGINAL amount alone on a continuation line

    /// The shape that used to fabricate a row: the foreign original amount
    /// ("USD 1.00 @ 1.3333") is printed on its own line with nothing else
    /// amount-shaped, and the real settled amount only arrives on a LATER
    /// line. The old single-match close path treated "1.00" as the closing
    /// amount, importing a fake £1.00 spend and leaking "@ 1.3333" into the
    /// next record's description. Every merchant/amount here is invented.
    func testForeignOriginalOnContinuationLineNeverFabricatesRow() throws {
        let lines = [
            "HSBC Premier Mastercard",
            "12 Jan 26 VIS FOREIGN MERCHANT",
            "USD 1.00 @ 1.3333",
            "London 0.75",
            "20 Jan 26 VIS ORDINARY SHOP",
            "Market Street 6.40",
        ]
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: lines), filename: "foreign.pdf")

        // No fabricated £1.00 row.
        XCTAssertFalse(stmt.transactions.contains { $0.amount == dec("1.00") })

        // The real settled amount (0.75) is what the record closes on.
        let foreign = stmt.transactions.first { $0.description.contains("FOREIGN MERCHANT") }
        XCTAssertNotNil(foreign)
        XCTAssertEqual(foreign?.amount, dec("0.75"))
        XCTAssertEqual(foreign?.originalAmount, dec("1.00"))
        XCTAssertEqual(foreign?.originalCurrency, "USD")

        // The "@ 1.3333" rate fragment does not leak into the NEXT record.
        let ordinary = stmt.transactions.first { $0.description.contains("ORDINARY SHOP") }
        XCTAssertNotNil(ordinary)
        XCTAssertFalse(ordinary?.description.contains("1.3333") ?? true)
        XCTAssertEqual(ordinary?.amount, dec("6.40"))

        XCTAssertEqual(stmt.transactions.count, 2)
    }

    /// A foreign-original annotation that never gets a settled amount at
    /// all (statement cuts off, page break, whatever) must warn — never
    /// import the bare original as if it were the real spend.
    func testForeignOriginalNeverSettledWarnsInsteadOfImporting() throws {
        let lines = [
            "HSBC Premier Mastercard",
            "05 Feb 26 VIS OVERSEAS MERCHANT",
            "USD 2.00 @ 1.3000",
            "10 Feb 26 VIS ORDINARY SHOP 6.40",
        ]
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: lines), filename: "unsettled.pdf")

        // The unsettled foreign-original record never becomes a row…
        XCTAssertFalse(stmt.transactions.contains { $0.description.contains("OVERSEAS MERCHANT") })
        XCTAssertFalse(stmt.transactions.contains { $0.amount == dec("2.00") })
        // …it warns instead of importing.
        XCTAssertTrue(stmt.warnings.contains { $0.contains("no amount found") && $0.contains("OVERSEAS MERCHANT") })
        // The next, unrelated record still parses fine.
        XCTAssertEqual(stmt.transactions.count, 1)
        XCTAssertEqual(stmt.transactions[0].description, "VIS ORDINARY SHOP")
        XCTAssertEqual(stmt.transactions[0].amount, dec("6.40"))
    }

    // MARK: - Loose marketing text no longer triggers balance-header mode

    /// Prose containing "balance" + a single column-phrase word ("deposit")
    /// must not flip the document into take-first/balance-column mode — the
    /// header co-location (or two-distinct-phrase) rule in I1 exists exactly
    /// to keep marketing boilerplate like this from being mistaken for a
    /// real "Date Description Paid out Paid in Balance" column caption.
    func testLooseMarketingTextDoesNotTriggerBalanceHeaderMode() throws {
        let lines = [
            "HSBC Premier Mastercard",
            "make a deposit to grow your balance",
            "02 Jun 2026 STARBUCKS CENTRAL 48.00 1,282.45",
            "05 Jun 2026 WELLCOME SUPERMARKET 90.10",
        ]
        let stmt = try PDFStatementImporter.parse(data: makePDF(lines: lines), filename: "marketing.pdf")

        // Without balance-header mode, a line with two trailing amounts is
        // the conservative warn-and-skip path, exactly like
        // testRunningBalanceLineIsWarningNotTransaction.
        XCTAssertEqual(stmt.transactions.count, 1)
        XCTAssertEqual(stmt.transactions[0].description, "WELLCOME SUPERMARKET")
        XCTAssertFalse(stmt.transactions.contains { $0.description.contains("STARBUCKS") })
        XCTAssertTrue(stmt.warnings.contains { $0.contains("running-balance column") })
    }
}
