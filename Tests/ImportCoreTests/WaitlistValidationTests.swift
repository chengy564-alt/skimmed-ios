import Foundation
import XCTest
@testable import ImportCore

final class WaitlistValidationTests: XCTestCase {

    func testValidEmailPasses() {
        XCTAssertTrue(WaitlistValidation.isValidEmail("hubert@example.com"))
    }

    func testEmailMissingAtSignFails() {
        XCTAssertFalse(WaitlistValidation.isValidEmail("hubertexample.com"))
    }

    func testEmailMissingDomainFails() {
        XCTAssertFalse(WaitlistValidation.isValidEmail("hubert@example"))
    }

    func testEmailIsTrimmedBeforeValidation() {
        XCTAssertTrue(WaitlistValidation.isValidEmail("  hubert@example.com  "))
    }

    func testEmptyCountryOrBankFailsNonEmptyCheck() {
        XCTAssertFalse(WaitlistValidation.isNonEmpty(""))
        XCTAssertFalse(WaitlistValidation.isNonEmpty("   "))
        XCTAssertTrue(WaitlistValidation.isNonEmpty("HK"))
    }

    func testFullEntryValidationRequiresAllThreeFields() {
        XCTAssertTrue(WaitlistValidation.isValidEntry(email: "a@b.com", country: "HK", bank: "HSBC"))
        XCTAssertFalse(WaitlistValidation.isValidEntry(email: "not-an-email", country: "HK", bank: "HSBC"))
        XCTAssertFalse(WaitlistValidation.isValidEntry(email: "a@b.com", country: "  ", bank: "HSBC"))
        XCTAssertFalse(WaitlistValidation.isValidEntry(email: "a@b.com", country: "HK", bank: ""))
    }
}
