import XCTest
@testable import ImportCore

final class MappingTemplateStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingTemplateStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTrip() throws {
        let store = MappingTemplateStore(directory: directory)
        let headers = ["Col1", "Col2", "Col3", "Col4"]
        let mapping = ColumnMapping(date: 0, description: 1, amount: 2,
                                    cardLast4: 3, dateFormat: "yyyy-MM-dd")

        XCTAssertNil(store.load(bank: "Acme Bank", headers: headers)) // nothing saved yet
        try store.save(mapping, bank: "Acme Bank", headers: headers)
        XCTAssertEqual(store.load(bank: "Acme Bank", headers: headers), mapping)

        // Different header shape or bank → different template, so no hit.
        XCTAssertNil(store.load(bank: "Acme Bank", headers: ["Col1", "Col2", "Col3"]))
        XCTAssertNil(store.load(bank: "Other Bank", headers: headers))
    }

    func testKeyIgnoresHeaderPunctuationAndCase() {
        // Normalized signatures keep re-exports of the same format on one template.
        let a = MappingTemplateStore.key(bank: "HSBC", headers: ["Post Date", "Amount (HKD)"])
        let b = MappingTemplateStore.key(bank: "hsbc", headers: ["post date", "amount hkd"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, MappingTemplateStore.key(bank: "HSBC", headers: ["Post Date"]))
    }
}
