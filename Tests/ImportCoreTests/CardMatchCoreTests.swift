import Foundation
import XCTest
@testable import ImportCore

final class CardMatchCoreTests: XCTestCase {

    func testExactBankAndLast4Match() {
        let existing = [CardIdentity(bank: "HSBC", last4: "4412"), CardIdentity(bank: "DBS", last4: "7731")]
        let result = CardMatchCore.proposals(bank: "HSBC", last4: "4412", existing: existing)
        XCTAssertEqual(result, .exact(0))
    }

    func testSingleCardOfBankSuggestedWhenLast4MissingOrMismatched() {
        let existing = [CardIdentity(bank: "HSBC", last4: "4412")]
        let result = CardMatchCore.proposals(bank: "HSBC", last4: "9999", existing: existing)
        XCTAssertEqual(result, .suggest(0))

        let resultNoLast4 = CardMatchCore.proposals(bank: "HSBC", last4: nil, existing: existing)
        XCTAssertEqual(resultNoLast4, .suggest(0))
    }

    func testMultipleCardsOfSameBankReturnsChoose() {
        let existing = [
            CardIdentity(bank: "HSBC", last4: "4412"),
            CardIdentity(bank: "HSBC", last4: "5566"),
        ]
        let result = CardMatchCore.proposals(bank: "HSBC", last4: "0000", existing: existing)
        XCTAssertEqual(result, .choose([0, 1]))
    }

    func testNoMatchingBankReturnsCreateNew() {
        let existing = [CardIdentity(bank: "HSBC", last4: "4412")]
        let result = CardMatchCore.proposals(bank: "Chase", last4: "1234", existing: existing)
        XCTAssertEqual(result, .createNew)
    }

    func testNilBankReturnsCreateNew() {
        let result = CardMatchCore.proposals(bank: nil, last4: "1234", existing: [])
        XCTAssertEqual(result, .createNew)
    }

    func testBankMatchingIsCaseInsensitive() {
        let existing = [CardIdentity(bank: "hsbc", last4: "4412")]
        let result = CardMatchCore.proposals(bank: "HSBC", last4: "4412", existing: existing)
        XCTAssertEqual(result, .exact(0))
    }
}
