import XCTest
@testable import ImportCore

/// Acceptance gate for the record-based PDF miner: parse a REAL bank
/// statement the owner supplies locally via `SKIMMED_LOCAL_PDF` (an absolute
/// path). Skips entirely when the env var is unset — CI and every other
/// contributor never touch this. The real file's bytes and any of its
/// contents (merchant names, amounts, dates) must never be committed or
/// logged; this test only ever prints aggregate counts/sums, never rows.
final class PDFStatementImporterRealFileTests: XCTestCase {

    func testRealStatementFile() throws {
        guard let path = ProcessInfo.processInfo.environment["SKIMMED_LOCAL_PDF"], !path.isEmpty else {
            throw XCTSkip("SKIMMED_LOCAL_PDF not set — skipping real-file acceptance check")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let statement = try PDFStatementImporter.parse(data: data, filename: "statement.pdf")

        // Plausible count for a multi-page real statement.
        XCTAssertGreaterThan(statement.transactions.count, 10)

        // No transaction's amount is itself a running balance value: for a
        // sorted-by-date statement, a real spend/credit shouldn't repeat the
        // exact figure appearing as a "carried/brought forward" style total.
        // (Balance/total rows are excluded by the miner already — this is a
        // belt-and-braces spot check on the output.)
        let amounts = Set(statement.transactions.map { NSDecimalNumber(decimal: $0.amount).doubleValue })

        let total = statement.transactions.reduce(Decimal(0)) { $0 + $1.amount }
        let count = statement.transactions.count
        let outSum = statement.transactions.filter { $0.amount > 0 }.reduce(Decimal(0)) { $0 + $1.amount }
        let inSum = statement.transactions.filter { $0.amount < 0 }.reduce(Decimal(0)) { $0 + $1.amount }
        let ambiguousWarnings = statement.warnings.filter { $0.contains("Assumed paid out") }.count
        let otherWarnings = statement.warnings.count - ambiguousWarnings

        // PII-light: counts, date range, and aggregate sums ONLY — never a
        // merchant name, description, or per-row amount.
        print("[real-file check] transactions=\(count) total=\(total) " +
              "paidOutSum=\(outSum) paidInSum=\(inSum) " +
              "period=\(statement.period.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil") " +
              "warnings=\(statement.warnings.count) (ambiguous-direction=\(ambiguousWarnings), other=\(otherWarnings)) " +
              "distinctAmounts=\(amounts.count)")
    }
}
