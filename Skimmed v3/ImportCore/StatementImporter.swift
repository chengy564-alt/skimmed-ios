import Foundation

/// ImportCore — format-agnostic entry point
///
/// `ImportFlowView` used to trust the file extension to pick CSVImporter vs
/// PDFStatementImporter, so a statement saved as "statement.txt" (or any
/// mis-extensioned export) never even reached the PDF path. Real files are
/// what they ARE, not what their name claims — sniff the actual bytes
/// instead: a PDF always opens with the "%PDF" magic number, whatever its
/// filename says; anything else is handed to CSVImporter, which already
/// tolerates the full range of plain-text export shapes.
public enum StatementImporter {

    /// `%PDF` — the first 4 bytes of every PDF file, mandated by the spec
    /// regardless of BOM/encoding preambles a text file might carry.
    static let pdfMagic: [UInt8] = [0x25, 0x50, 0x44, 0x46] // "%PDF"

    /// Content-sniffed parse: PDF magic number → PDFStatementImporter,
    /// otherwise CSVImporter. `filename` still flows through as a bank-hint
    /// fallback and for the `.needsMapping` mapping-template lookup; it's no
    /// longer what decides which parser runs.
    public static func parse(data: Data, filename: String) throws -> ParsedStatement {
        if data.prefix(pdfMagic.count).elementsEqual(pdfMagic) {
            return try PDFStatementImporter.parse(data: data, filename: filename)
        }
        return try CSVImporter.parse(data: data, filename: filename)
    }
}
