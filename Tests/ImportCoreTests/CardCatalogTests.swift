import XCTest
@testable import ImportCore

final class CardCatalogTests: XCTestCase {

    // MARK: - Country-specific filtering

    func testInstitutionsAreMarketSpecific() {
        let hk = CardCatalog.institutions(market: "HK")
        let gb = CardCatalog.institutions(market: "GB")
        XCTAssertTrue(hk.contains { $0.id == "hsbc-hk" })
        XCTAssertFalse(hk.contains { $0.id == "hsbc-gb" })
        XCTAssertTrue(gb.contains { $0.id == "hsbc-gb" })
        XCTAssertFalse(gb.contains { $0.id == "hsbc-hk" })
    }

    func testPopularInstitutionsFirst() {
        let us = CardCatalog.institutions(market: "US")
        let firstUnpopular = us.firstIndex { !$0.isPopular } ?? us.count
        XCTAssertTrue(us.prefix(firstUnpopular).allSatisfy(\.isPopular))
        XCTAssertTrue(us.suffix(from: firstUnpopular).allSatisfy { !$0.isPopular })
    }

    func testSearchFiltersWithinMarket() {
        let hits = CardCatalog.searchInstitutions(market: "GB", query: "monzo")
        XCTAssertEqual(hits.map(\.id), ["monzo-gb"])
        XCTAssertTrue(CardCatalog.searchInstitutions(market: "HK", query: "monzo").isEmpty)
        // Empty query = full market list.
        XCTAssertEqual(CardCatalog.searchInstitutions(market: "HK", query: "").count,
                       CardCatalog.institutions(market: "HK").count)
    }

    func testPlannedMarketsAllSeeded() {
        for market in ["HK", "US", "GB", "SG", "CA", "AU", "NZ", "JP", "KR", "TW", "DE", "FR", "NL", "ES", "IT", "AE", "INTL"] {
            XCTAssertFalse(CardCatalog.institutions(market: market).isEmpty, "no institutions for \(market)")
        }
    }

    // MARK: - Alias detection / migration mapping

    func testDetectedBankNameMapsToMarketInstitution() {
        // BankDetector emits brand-level names; each maps per-market.
        XCTAssertEqual(CardCatalog.institution(named: "HSBC", market: "HK")?.id, "hsbc-hk")
        XCTAssertEqual(CardCatalog.institution(named: "HSBC", market: "GB")?.id, "hsbc-gb")
        XCTAssertEqual(CardCatalog.institution(named: "Hang Seng", market: "HK")?.id, "hangseng-hk")
        XCTAssertEqual(CardCatalog.institution(named: "Revolut", market: "INTL")?.id, "revolut-intl")
    }

    func testCrossMarketNameNeverFuzzyMatchesHomeMarket() {
        // The reported bug: home market HK + picking "HSBC UK" showed HSBC
        // Hong Kong's cards. An exact cross-market institution name must win
        // regardless of the requested market.
        XCTAssertEqual(CardCatalog.institution(named: "HSBC UK", market: "HK")?.id, "hsbc-gb")
        XCTAssertEqual(CardCatalog.institution(named: "HSBC Hong Kong", market: "US")?.id, "hsbc-hk")
        XCTAssertEqual(CardCatalog.institution(named: "Citibank Singapore", market: "HK")?.id, "citi-sg")
        // Brand-only names still resolve within the requested market.
        XCTAssertEqual(CardCatalog.institution(named: "HSBC", market: "HK")?.id, "hsbc-hk")
        XCTAssertEqual(CardCatalog.institution(named: "HSBC", market: "GB")?.id, "hsbc-gb")
    }

    func testPopularInstitutionsHaveRealLineups() {
        // "Not every card is there" fix: popular institutions must offer a
        // real choice, not a single flagship.
        for inst in CardCatalog.seed where inst.isPopular && inst.market != "INTL" {
            XCTAssertGreaterThanOrEqual(
                CardCatalog.products(institutionID: inst.id).count, 2,
                "\(inst.id) has a thin lineup"
            )
        }
    }

    func testLegacyFreeTextBankNamesMap() {
        // Pre-catalogue ImportedCard.bank values (the migration path).
        XCTAssertEqual(CardCatalog.institution(named: "Standard Chartered", market: "HK")?.id, "sc-hk")
        XCTAssertEqual(CardCatalog.institution(named: "bank of china", market: "HK")?.id, "boc-hk")
    }

    // MARK: - Unknown bank/card fallback

    func testUnknownBankReturnsNilNeverThrows() {
        XCTAssertNil(CardCatalog.institution(named: "My Tiny Credit Union", market: "US"))
        XCTAssertNil(CardCatalog.institution(named: "", market: "US"))
        XCTAssertTrue(CardCatalog.searchInstitutions(market: "US", query: "zzzznope").isEmpty)
    }

    // MARK: - Products

    func testProductsBelongToTheirInstitution() {
        let products = CardCatalog.products(institutionID: "hsbc-hk")
        XCTAssertFalse(products.isEmpty)
        XCTAssertTrue(products.allSatisfy { $0.institutionID == "hsbc-hk" && $0.market == "HK" })
    }

    func testProductSearchAndStatementNaming() {
        XCTAssertEqual(CardCatalog.searchProducts(institutionID: "chase-us", query: "sapphire").count, 2)
        // Statement text explicitly naming a product → preselect with evidence.
        let named = CardCatalog.productNamed(in: "CHASE SAPPHIRE RESERVE STATEMENT 03/2026", institutionID: "chase-us")
        XCTAssertEqual(named?.id, "chase-us-csr")
        XCTAssertNil(CardCatalog.productNamed(in: "generic statement text", institutionID: "chase-us"))
    }

    func testNoInventedFeeData() {
        // Integrity rule: a published fee may only exist alongside the issuer
        // source it was verified against and the date it was checked.
        for product in CardCatalog.productSeed where product.publishedFXFeePct != nil {
            XCTAssertNotNil(product.sourceURL, "\(product.id) has a fee but no source")
            XCTAssertNotNil(product.lastVerifiedAt, "\(product.id) has a fee but no verification date")
            XCTAssertTrue(product.sourceURL!.hasPrefix("https://"), "\(product.id) source isn't a URL")
        }
    }

    func testVerifiedFeeTrancheExists() {
        // Issuer-verified tranches (2026-07-13): US/UK/HK/CA/AU majors.
        let verified = CardCatalog.productSeed.filter { $0.publishedFXFeePct != nil }
        XCTAssertGreaterThanOrEqual(verified.count, 30)
        // Sanity bounds: published FX fees live in [0, 5)%.
        XCTAssertTrue(verified.allSatisfy { (0..<5).contains($0.publishedFXFeePct!) })
    }

    func testEveryProductInstitutionExists() {
        for product in CardCatalog.productSeed {
            XCTAssertNotNil(CardCatalog.institution(id: product.institutionID),
                            "\(product.id) references missing institution \(product.institutionID)")
        }
    }
}
