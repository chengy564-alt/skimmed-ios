import XCTest
@testable import ImportCore

final class TripPlanCoreTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - Statement date window

    func testWindowSingleMonthTrip() {
        // Trip fully inside March, buffer stays in March.
        let window = TripPlanCore.statementWindow(start: date(2026, 3, 3), end: date(2026, 3, 10))
        XCTAssertEqual(window.months.count, 1)
        XCTAssertEqual(calendar.component(.month, from: window.months[0]), 3)
        XCTAssertEqual(window.end, date(2026, 3, 17)) // +7-day settlement buffer
    }

    func testWindowBufferSpillsIntoNextMonth() {
        // Trip ends Mar 28; +7 days lands Apr 4 → needs March AND April.
        let window = TripPlanCore.statementWindow(start: date(2026, 3, 20), end: date(2026, 3, 28))
        XCTAssertEqual(window.months.map { calendar.component(.month, from: $0) }, [3, 4])
    }

    func testWindowMultiMonthTripAcrossYearEnd() {
        let window = TripPlanCore.statementWindow(start: date(2025, 12, 20), end: date(2026, 1, 5))
        XCTAssertEqual(window.months.map { calendar.component(.month, from: $0) }, [12, 1])
        XCTAssertEqual(window.months.map { calendar.component(.year, from: $0) }, [2025, 2026])
    }

    func testWindowSentenceMentionsEveryMonth() {
        let window = TripPlanCore.statementWindow(start: date(2026, 3, 20), end: date(2026, 3, 28))
        let sentence = TripPlanCore.windowSentence(window)
        XCTAssertTrue(sentence.contains("March 2026"))
        XCTAssertTrue(sentence.contains("April 2026"))
        XCTAssertTrue(sentence.contains("Apr 4"))
    }

    // MARK: - Coverage checklist

    func testMissingCardsCaseAndWhitespaceInsensitive() {
        let missing = TripPlanCore.missingCards(
            expected: ["HSBC Red", "DBS Black", "Amex Gold"],
            covered: [" hsbc red ", "dbs black"]
        )
        XCTAssertEqual(missing, ["Amex Gold"])
    }

    func testStageProgression() {
        var trip = PlannedTrip(destinationCountry: "JP", startDate: date(2026, 3, 1), end: date(2026, 3, 10))
        XCTAssertEqual(trip.stage(coveredCards: []), .planning)

        trip.expectedCards = ["HSBC Red", "DBS Black"]
        trip.attachedCardIDs = [UUID()]
        XCTAssertEqual(trip.stage(coveredCards: ["HSBC Red"]), .partial)
        XCTAssertEqual(trip.stage(coveredCards: ["HSBC Red", "DBS Black"]), .complete)
    }

    // MARK: - Persistence shape (Codable round trip = what the JSON files hold)

    func testPlannedTripCodableRoundTrip() throws {
        // Whole-second createdAt: ISO8601 encoding drops sub-second precision.
        let trip = PlannedTrip(
            destinationCountry: "TH", label: "Bangkok food run",
            startDate: date(2026, 2, 1), endDate: date(2026, 2, 9),
            expectedCards: ["HSBC Red"], attachedCardIDs: [UUID()],
            transactionIDs: [UUID(), UUID()], createdAt: date(2026, 7, 1)
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PlannedTrip.self, from: encoder.encode(trip))
        XCTAssertEqual(decoded, trip)
    }

    func testMigrationDefaultIsEmptyList() throws {
        // Pre-v1.1 installs have no plannedtrips.json — decoding "nothing"
        // must yield [], which is what Persistence's `?? []` produces.
        let decoder = JSONDecoder()
        let empty = try decoder.decode([PlannedTrip].self, from: Data("[]".utf8))
        XCTAssertEqual(empty, [])
    }

    // MARK: - Multiple statements/cards per trip

    func testMultipleCardsAccumulateOnOneTrip() {
        var trip = PlannedTrip(destinationCountry: "JP", startDate: date(2026, 3, 1), end: date(2026, 3, 10))
        let cardA = UUID(), cardB = UUID()
        // Same accumulation AppStore.attach performs.
        for (card, txs) in [(cardA, [UUID(), UUID()]), (cardB, [UUID()]), (cardA, [UUID()])] {
            if !trip.attachedCardIDs.contains(card) { trip.attachedCardIDs.append(card) }
            trip.transactionIDs.append(contentsOf: txs)
        }
        XCTAssertEqual(trip.attachedCardIDs, [cardA, cardB]) // no duplicate card
        XCTAssertEqual(trip.transactionIDs.count, 4)
    }

    // MARK: - UserCardLink rematch

    func testLinkRematchExactInstitutionAndLast4() {
        let links = [
            UserCardLink(institutionID: "hsbc-hk", last4: "4412", productID: "hsbc-hk-red", source: .manual),
            UserCardLink(institutionID: "hsbc-hk", last4: "9999", productID: "hsbc-hk-everymile", source: .manual),
        ]
        XCTAssertEqual(UserCardLink.match(institutionID: "hsbc-hk", last4: "4412", in: links)?.productID, "hsbc-hk-red")
        XCTAssertNil(UserCardLink.match(institutionID: "hsbc-hk", last4: "1111", in: links))
        XCTAssertNil(UserCardLink.match(institutionID: "dbs-hk", last4: "4412", in: links))
        // last4-less links only rematch last4-less imports.
        let nilLink = [UserCardLink(institutionID: "mox-hk", last4: nil, productID: "mox-hk-card", source: .manual)]
        XCTAssertNotNil(UserCardLink.match(institutionID: "mox-hk", last4: nil, in: nilLink))
        XCTAssertNil(UserCardLink.match(institutionID: "mox-hk", last4: "1234", in: nilLink))
    }

    // MARK: - Evidence labels

    func testEvidenceLabelDisplayNames() {
        XCTAssertEqual(EvidenceLabel.observed.display, "Observed")
        XCTAssertEqual(EvidenceLabel.published.display, "Published")
        XCTAssertEqual(EvidenceLabel.estimated.display, "Estimated")
        XCTAssertEqual(EvidenceLabel.insufficient.display, "Insufficient evidence")
    }
}

private extension PlannedTrip {
    /// Test sugar — the production init takes endDate by full label.
    init(destinationCountry: String, startDate: Date, end: Date) {
        self.init(destinationCountry: destinationCountry, startDate: startDate, endDate: end)
    }
}
