import XCTest
import CoreGraphics
import CoreText
@testable import ImportCore

/// Content-sniffing: StatementImporter.parse must pick the right engine off
/// the bytes, not the filename — a mis-extensioned export is still real.
final class StatementImporterTests: XCTestCase {

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

    func testPDFBytesRouteToPDFImporterRegardlessOfExtension() throws {
        let data = makePDF(lines: [
            "Monzo",
            "03/06/2026 GREGGS MANCHESTER 4.20",
            "15/06/2026 TESCO EXPRESS LONDON 18.75",
        ])
        // Deliberately wrong extension — the ".csv" name must not matter.
        let stmt = try StatementImporter.parse(data: data, filename: "statement.csv")
        XCTAssertEqual(stmt.transactions.count, 2)
        XCTAssertEqual(stmt.bankHint, "Monzo")
    }

    func testCSVBytesRouteToCSVImporterRegardlessOfExtension() throws {
        let csv = "Date,Description,Amount\n2026-01-01,COFFEE SHOP,4.50\n2026-01-02,GROCERY STORE,32.10\n"
        let data = Data(csv.utf8)
        // Deliberately wrong extension — no "%PDF" magic, so CSV wins.
        let stmt = try StatementImporter.parse(data: data, filename: "statement.pdf")
        XCTAssertEqual(stmt.transactions.count, 2)
    }
}
