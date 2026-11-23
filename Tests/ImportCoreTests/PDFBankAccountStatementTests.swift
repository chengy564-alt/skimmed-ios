import XCTest
@testable import ImportCore

/// Regression fixture for the HSBC One BANK-ACCOUNT statement bug: a
/// portfolio-summary page dense with balances, an FX rate, and reference
/// numbers was mined into ~30 fake transactions, one carrying the exchange
/// rate 10.397545 as a 10.4-million-unit foreign original (the HK$-106M
/// markup). Layout anonymized from the reproducing statement.
final class PDFBankAccountStatementTests: XCTestCase {

    private let statementText = """
    The Hongkong and Shanghai Banking Corporation Limited HSBC One 2233 3000
    MR CHAN TAI MAN
    FLAT A, 1/F, BLK 1
    Number : 123-456789-001
    Branch : CENTRAL
    Page 1 of 2
    6 December 2025
    HSBC One Portfolio
    HKD Equivalent
    (DR=Debit )
    Total balance in HKD 166.79
    Total balance in Foreign Currency 0.52
    Total balance in Statement Gold 0.00
    Total balance in Overdraft 0.00
    Net Position 167.31
    Portfolio Summary
    Account Number CCY Exchange Rate Balance
    (DR=Debit )
    HKD Equivalent
    (DR=Debit )
    HSBC One - Deposits
    HKD Savings 123-456789-001 HKD 127.91 127.91
    HKD Current HKD 38.88 38.88
    FCY Savings GBP 10.397545 0.05 0.52
    Total 167.31
    HSBC One Account Transaction History
    HKD Savings
    Date Transaction Details Deposit Withdrawal Balance
    7 Nov B/F BALANCE 7.91
    6 Dec WONG SIU MING
    NC0512345678(05DEC25) 120.00 127.91
    HKD Current
    Date Transaction Details Deposit Withdrawal Balance
    7 Nov B/F BALANCE 38.88
    Foreign Currency Savings
    CCY Date Transaction Details Deposit Withdrawal Balance
    GBP 7 Nov B/F BALANCE 0.05
    Total Relationship Balance
    Your average Total Relationship Balance was HK$642.98 from 1 September 2025 to 30 November 2025.
    Important Notice
    We notice that there have been fraudulent telephone calls that claim to be from HSBC.
    """

    func testMinesOnlyTheRealTransaction() throws {
        let statement = try PDFStatementImporter.parse(text: statementText, filename: "eStatementFile_20260102.pdf")
        // One real row: the HK$120.00 transfer. Every balance, rate, total,
        // and portfolio line is furniture.
        XCTAssertEqual(statement.transactions.count, 1,
                       "mined: \(statement.transactions.map { "\($0.description) \($0.amount)" })")
        let tx = statement.transactions[0]
        XCTAssertEqual(tx.amount, 120)
        XCTAssertTrue(tx.description.contains("WONG SIU MING"))
    }

    func testNoRowCarriesTheExchangeRateAsForeignOriginal() throws {
        let statement = try PDFStatementImporter.parse(text: statementText, filename: "s.pdf")
        for tx in statement.transactions {
            XCTAssertLessThan(abs(NSDecimalNumber(decimal: tx.originalAmount ?? 0).doubleValue), 1_000_000,
                              "\(tx.description) carries an absurd original amount")
            XCTAssertLessThan(abs(NSDecimalNumber(decimal: tx.amount).doubleValue), 1_000_000)
        }
    }

    func testRateTokenIsNotMoneyShaped() {
        // "10.397545" is a rate; "12,300" and "1,234.56" are money.
        XCTAssertNil(PDFStatementImporter.firstForeignAmount(in: "FCY Savings GBP 10.397545", commaDecimal: false)?.code)
        XCTAssertEqual(PDFStatementImporter.firstForeignAmount(in: "JPY 12,300 spent", commaDecimal: false)?.value, 12300)
        XCTAssertEqual(PDFStatementImporter.firstForeignAmount(in: "GBP 1,234.56 charged", commaDecimal: false)?.value, Decimal(string: "1234.56"))
    }
}
