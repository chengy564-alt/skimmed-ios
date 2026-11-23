import XCTest
@testable import ImportCore

/// LIVE integration check against the real ECB Statistical Data Warehouse.
/// The rest of the rate suite mocks the network (correct for CI); this one
/// actually hits `data-api.ecb.europa.eu` so a change to ECB's URL scheme or
/// CSV schema is caught instead of silently breaking repricing in production.
///
/// Skips unless `SKIMMED_LIVE_ECB=1` — CI and every offline run never touch
/// the network. Uses a fixed historical WEEKDAY so it stays stable forever
/// (ECB publishes no weekend/holiday observations). ECB's API is free,
/// public, and unauthenticated — no key, no account, no charge.
final class ECBLiveIntegrationTests: XCTestCase {

    private static let liveDay = "2024-01-15" // a Monday — guaranteed ECB data

    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["SKIMMED_LIVE_ECB"] == "1" else {
            throw XCTSkip("SKIMMED_LIVE_ECB not set — skipping live ECB network test")
        }
    }

    /// Raw HTTP + CSV schema: the endpoint responds 200 and the payload still
    /// parses into per-currency observations for both requested currencies.
    func testLiveFetchAndParseSchema() async throws {
        try requireLive()
        let client = ECBRateHTTPClient()
        let data = try await client.fetch(
            currencies: ["JPY", "HKD"],
            startDay: Self.liveDay,
            endDay: Self.liveDay
        )
        let observations = try ECBRateCSVParser.parse(data)
        XCTAssertTrue(observations.contains { $0.currency == "JPY" }, "no JPY observation in live payload")
        XCTAssertTrue(observations.contains { $0.currency == "HKD" }, "no HKD observation in live payload")
        for obs in observations {
            XCTAssertEqual(obs.day, Self.liveDay)
            XCTAssertGreaterThan(obs.unitsPerEUR, 0, "\(obs.currency) unitsPerEUR must be positive")
        }
    }

    /// End-to-end repository path: a real cross-rate request resolves to an
    /// ECB-verified quote (the exact path an import's `refreshProvisionalRates`
    /// drives). Broad sanity band so normal rate drift never flakes it.
    func testLiveRepositoryResolvesVerifiedCrossRate() async throws {
        try requireLive()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ecb-live-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let repo = HistoricalRateRepository(cacheURL: cacheURL) // real ECBRateHTTPClient
        let thbToHKD = HistoricalRateRequest(from: "THB", to: "HKD", day: Self.liveDay)
        let jpyToHKD = HistoricalRateRequest(from: "JPY", to: "HKD", day: Self.liveDay)

        let quotes = await repo.resolve([thbToHKD, jpyToHKD], policy: .verifiedOnly)

        let thb = try XCTUnwrap(quotes[thbToHKD], "THB→HKD did not resolve against live ECB")
        XCTAssertEqual(thb.source, .ecb)
        XCTAssertEqual(thb.status, .verified)
        // THB→HKD historically sits around 0.20–0.25; keep a wide sane band.
        XCTAssertGreaterThan(thb.rate, 0.1)
        XCTAssertLessThan(thb.rate, 0.5)

        let jpy = try XCTUnwrap(quotes[jpyToHKD], "JPY→HKD did not resolve against live ECB")
        XCTAssertEqual(jpy.source, .ecb)
        XCTAssertEqual(jpy.status, .verified)
        // JPY→HKD historically sits around 0.045–0.060.
        XCTAssertGreaterThan(jpy.rate, 0.02)
        XCTAssertLessThan(jpy.rate, 0.10)
    }

    /// The request URL carries only public rate dimensions and dates — never
    /// account, merchant, or amount data. Re-asserted here on the live path.
    func testLiveRequestURLLeaksNoPrivateData() async throws {
        try requireLive()
        let client = ECBRateHTTPClient()
        let url = try client.requestURL(currencies: ["JPY", "HKD"], startDay: Self.liveDay, endDay: Self.liveDay)
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://data-api.ecb.europa.eu/service/data/EXR/"))
        XCTAssertTrue(s.contains("EUR.SP00.A"))
        // Only currency codes + dates + format flags — nothing user-specific.
        XCTAssertFalse(s.lowercased().contains("account"))
        XCTAssertFalse(s.lowercased().contains("card"))
    }
}
