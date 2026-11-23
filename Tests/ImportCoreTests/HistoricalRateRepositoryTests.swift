import Foundation
import XCTest
@testable import ImportCore

final class HistoricalRateRepositoryTests: XCTestCase {
    private enum TestError: Error { case offline }

    private actor FakeECBFetcher: ECBRateFetching {
        var result: Result<Data, Error>
        private(set) var calls: [(currencies: Set<String>, startDay: String, endDay: String)] = []

        init(result: Result<Data, Error>) {
            self.result = result
        }

        func fetch(currencies: Set<String>, startDay: String, endDay: String) async throws -> Data {
            calls.append((currencies, startDay, endDay))
            return try result.get()
        }

        func setResult(_ result: Result<Data, Error>) {
            self.result = result
        }
    }

    private actor ExactDayECBFetcher: ECBRateFetching {
        let expandedData: Data
        let exactData: Data
        private(set) var calls: [(currencies: Set<String>, startDay: String, endDay: String)] = []

        init(expandedData: Data, exactData: Data) {
            self.expandedData = expandedData
            self.exactData = exactData
        }

        func fetch(currencies: Set<String>, startDay: String, endDay: String) async throws -> Data {
            calls.append((currencies, startDay, endDay))
            return startDay == endDay ? exactData : expandedData
        }
    }

    private actor RoutedDayECBFetcher: ECBRateFetching {
        let expandedData: Data
        let exactDataByDay: [String: Data]
        private(set) var calls: [(currencies: Set<String>, startDay: String, endDay: String)] = []

        init(expandedData: Data, exactDataByDay: [String: Data]) {
            self.expandedData = expandedData
            self.exactDataByDay = exactDataByDay
        }

        func fetch(currencies: Set<String>, startDay: String, endDay: String) async throws -> Data {
            calls.append((currencies, startDay, endDay))
            if startDay == endDay, let exact = exactDataByDay[startDay] {
                return exact
            }
            return expandedData
        }
    }

    private let sampleCSV = """
    KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
    EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-05,9.1185
    EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-05,37.987
    EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2026-06-05,1.164
    """

    func testResolvedECBQuotePersistsAndSecondRepositoryReadsCache() async throws {
        let cacheURL = try makeTemporaryDirectory().appendingPathComponent("rates.json")
        let online = FakeECBFetcher(result: .success(Data(sampleCSV.utf8)))
        let request = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-05")
        let first = HistoricalRateRepository(cacheURL: cacheURL, fetcher: online)

        let firstQuote = await first.resolve([request], policy: .allowFallback)[request]

        XCTAssertEqual(firstQuote?.source, .ecb)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        let offline = FakeECBFetcher(result: .failure(TestError.offline))
        let second = HistoricalRateRepository(cacheURL: cacheURL, fetcher: offline)
        let cachedQuote = await second.resolve([request], policy: .verifiedOnly)[request]
        let offlineCallCount = await offline.calls.count

        XCTAssertEqual(cachedQuote, firstQuote)
        XCTAssertEqual(offlineCallCount, 0)
    }

    func testPreviousObservationDoesNotPreventFetchingANewerRequestedDay() async throws {
        let fridayCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-05,9.1185
        EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-05,37.987
        """
        let mondayCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-08,9.2000
        EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-08,36.8000
        """
        let fetcher = FakeECBFetcher(result: .success(Data(fridayCSV.utf8)))
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: fetcher
        )

        let friday = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-05")
        _ = await repository.resolve([friday], policy: .verifiedOnly)
        await fetcher.setResult(.success(Data(mondayCSV.utf8)))

        let monday = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-08")
        let quote = await repository.resolve([monday], policy: .verifiedOnly)[monday]
        let calls = await fetcher.calls

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(quote?.observationDay, "2026-06-08")
        XCTAssertEqual(quote?.rate, Decimal(string: "0.25"))
    }

    func testKnownWeekendCoverageReusesNearestPreviousObservation() async throws {
        let fetcher = FakeECBFetcher(result: .success(Data(sampleCSV.utf8)))
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: fetcher
        )
        let sunday = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-07")

        let first = await repository.resolve([sunday], policy: .verifiedOnly)[sunday]
        let second = await repository.resolve([sunday], policy: .verifiedOnly)[sunday]
        let calls = await fetcher.calls

        XCTAssertEqual(first?.observationDay, "2026-06-05")
        XCTAssertEqual(second, first)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.startDay, "2026-06-05")
        XCTAssertEqual(calls.last?.endDay, "2026-06-05")
    }

    func testTruncatedWeekendRangeDoesNotAuthorizeANonNearestObservation() async throws {
        let thursdayCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-04,9.1000
        EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-04,37.9000
        """
        let fetcher = FakeECBFetcher(result: .success(Data(thursdayCSV.utf8)))
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: fetcher
        )
        let sunday = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-07")

        let quote = await repository.resolve([sunday], policy: .allowFallback)[sunday]
        let calls = await fetcher.calls

        XCTAssertEqual(quote?.source, .bundledFallback)
        XCTAssertEqual(quote?.status, .provisional)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.startDay, "2026-06-05")
    }

    func testWeekendHolidayWalksBackToAConfirmedPriorBusinessDay() async throws {
        let thursdayCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-04,9.1000
        EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-04,37.9000
        """
        let emptyCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        """
        let fetcher = RoutedDayECBFetcher(
            expandedData: Data(thursdayCSV.utf8),
            exactDataByDay: [
                "2026-06-05": Data(emptyCSV.utf8),
                "2026-06-04": Data(thursdayCSV.utf8),
            ]
        )
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: fetcher
        )
        let sunday = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-07")

        let first = await repository.resolve([sunday], policy: .verifiedOnly)[sunday]
        let second = await repository.resolve([sunday], policy: .verifiedOnly)[sunday]
        let calls = await fetcher.calls

        XCTAssertEqual(first?.observationDay, "2026-06-04")
        XCTAssertEqual(second, first)
        XCTAssertEqual(calls.count, 3)
    }

    func testOfflineAllowFallbackIsProvisionalButVerifiedOnlyReturnsNil() async throws {
        let fetcher = FakeECBFetcher(result: .failure(TestError.offline))
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: fetcher
        )
        let request = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-05")

        let fallback = await repository.resolve([request], policy: .allowFallback)[request]
        let verifiedOnly = await repository.resolve([request], policy: .verifiedOnly)[request]

        XCTAssertEqual(fallback?.source, .bundledFallback)
        XCTAssertEqual(fallback?.status, .provisional)
        XCTAssertNil(verifiedOnly)
    }

    func testBatchesRequestsIntoOneExpandedDateRange() async throws {
        let fetcher = FakeECBFetcher(result: .success(Data(sampleCSV.utf8)))
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: fetcher
        )
        let requests: Set<HistoricalRateRequest> = [
            .init(from: "THB", to: "HKD", day: "2026-06-05"),
            .init(from: "USD", to: "HKD", day: "2026-06-07"),
        ]

        _ = await repository.resolve(requests, policy: .allowFallback)
        let calls = await fetcher.calls

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.currencies, ["HKD", "THB", "USD"])
        XCTAssertEqual(calls.first?.startDay, "2026-05-29")
        XCTAssertEqual(calls.first?.endDay, "2026-06-07")
        XCTAssertEqual(calls.last?.currencies, ["HKD", "USD"])
        XCTAssertEqual(calls.last?.startDay, "2026-06-05")
        XCTAssertEqual(calls.last?.endDay, "2026-06-05")
    }

    func testCorruptCacheIsDiscardedAndRebuilt() async throws {
        let directory = try makeTemporaryDirectory()
        let cacheURL = directory.appendingPathComponent("rates.json")
        try Data("not-json".utf8).write(to: cacheURL)
        let fetcher = FakeECBFetcher(result: .success(Data(sampleCSV.utf8)))
        let repository = HistoricalRateRepository(cacheURL: cacheURL, fetcher: fetcher)
        let request = HistoricalRateRequest(from: "USD", to: "HKD", day: "2026-06-05")

        let quote = await repository.resolve([request], policy: .verifiedOnly)[request]

        XCTAssertEqual(quote?.source, .ecb)
        XCTAssertNoThrow(try JSONDecoder().decode(
            HistoricalRateBook.self,
            from: Data(contentsOf: cacheURL)
        ))
    }

    func testValidJSONCacheWithDuplicateAndInvalidObservationsIsSanitized() async throws {
        let cacheURL = try makeTemporaryDirectory().appendingPathComponent("rates.json")
        let corruptButDecodable = """
        {
          "observations": [
            {"currency":"HKD","day":"2026-06-05","unitsPerEUR":9.0},
            {"currency":"HKD","day":"2026-06-05","unitsPerEUR":9.1},
            {"currency":"THB","day":"2026-06-05","unitsPerEUR":-37}
          ]
        }
        """
        try Data(corruptButDecodable.utf8).write(to: cacheURL)
        let fetcher = FakeECBFetcher(result: .success(Data(sampleCSV.utf8)))
        let repository = HistoricalRateRepository(cacheURL: cacheURL, fetcher: fetcher)
        let request = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-05")

        let quote = await repository.resolve([request], policy: .verifiedOnly)[request]
        let calls = await fetcher.calls

        XCTAssertEqual(quote?.rate, dec("9.1185") / dec("37.987"))
        XCTAssertEqual(calls.count, 1)
    }

    func testPartialValidResponseResolvesOnlyItsValidCurrencies() async throws {
        let mixedCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-05,9.1185
        EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-05,not-a-number
        EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2026-06-05,1.164
        """
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: FakeECBFetcher(result: .success(Data(mixedCSV.utf8)))
        )
        let usd = HistoricalRateRequest(from: "USD", to: "HKD", day: "2026-06-05")
        let thb = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-05")

        let quotes = await repository.resolve([usd, thb], policy: .allowFallback)

        XCTAssertEqual(quotes[usd]?.source, .ecb)
        XCTAssertEqual(quotes[thb]?.source, .bundledFallback)
        XCTAssertEqual(quotes[thb]?.status, .provisional)
    }

    func testMalformedRequestedDayDoesNotAuthorizeAnOlderVerifiedQuote() async throws {
        let mixedCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-05,9.1185
        EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-05,37.987
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-08,9.2000
        EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-08,not-a-number
        """
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: FakeECBFetcher(result: .success(Data(mixedCSV.utf8)))
        )
        let request = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-08")

        let quote = await repository.resolve([request], policy: .allowFallback)[request]

        XCTAssertEqual(quote?.source, .bundledFallback)
        XCTAssertEqual(quote?.status, .provisional)
    }

    func testSilentlyOmittedWeekdayDoesNotAuthorizeAnOlderVerifiedQuote() async throws {
        let truncatedCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-05,9.1185
        EXR.D.THB.EUR.SP00.A,D,THB,EUR,SP00,A,2026-06-05,37.987
        """
        let fetcher = FakeECBFetcher(result: .success(Data(truncatedCSV.utf8)))
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: fetcher
        )
        let monday = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-08")

        let quote = await repository.resolve([monday], policy: .allowFallback)[monday]
        let calls = await fetcher.calls

        XCTAssertEqual(quote?.source, .bundledFallback)
        XCTAssertEqual(quote?.status, .provisional)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.startDay, "2026-06-08")
        XCTAssertEqual(calls.last?.endDay, "2026-06-08")
    }

    func testCleanEmptyExactDayConfirmsAWeekdayHoliday() async throws {
        let emptyCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        """
        let fetcher = ExactDayECBFetcher(
            expandedData: Data(sampleCSV.utf8),
            exactData: Data(emptyCSV.utf8)
        )
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: fetcher
        )
        let monday = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-08")

        let first = await repository.resolve([monday], policy: .verifiedOnly)[monday]
        let second = await repository.resolve([monday], policy: .verifiedOnly)[monday]
        let calls = await fetcher.calls

        XCTAssertEqual(first?.source, .ecb)
        XCTAssertEqual(first?.observationDay, "2026-06-05")
        XCTAssertEqual(second, first)
        XCTAssertEqual(calls.count, 2)
    }

    func testPartialExactDayResponseDoesNotCoverAnOmittedCurrency() async throws {
        let partialMondayCSV = """
        KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
        EXR.D.HKD.EUR.SP00.A,D,HKD,EUR,SP00,A,2026-06-08,9.2000
        """
        let fetcher = ExactDayECBFetcher(
            expandedData: Data(sampleCSV.utf8),
            exactData: Data(partialMondayCSV.utf8)
        )
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: fetcher
        )
        let monday = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-08")

        let quote = await repository.resolve([monday], policy: .allowFallback)[monday]

        XCTAssertEqual(quote?.source, .bundledFallback)
        XCTAssertEqual(quote?.status, .provisional)
    }

    func testMalformedResponseFallsBackWithoutCachingIt() async throws {
        let cacheURL = try makeTemporaryDirectory().appendingPathComponent("rates.json")
        let fetcher = FakeECBFetcher(result: .success(Data("bad-response".utf8)))
        let repository = HistoricalRateRepository(cacheURL: cacheURL, fetcher: fetcher)
        let request = HistoricalRateRequest(from: "THB", to: "HKD", day: "2026-06-05")

        let quote = await repository.resolve([request], policy: .allowFallback)[request]

        XCTAssertEqual(quote?.source, .bundledFallback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testUnsupportedCurrencyReturnsNoInventedFallback() async throws {
        let repository = HistoricalRateRepository(
            cacheURL: try makeTemporaryDirectory().appendingPathComponent("rates.json"),
            fetcher: FakeECBFetcher(result: .failure(TestError.offline))
        )
        let request = HistoricalRateRequest(from: "XYZ", to: "HKD", day: "2026-06-05")

        let quote = await repository.resolve([request], policy: .allowFallback)[request]

        XCTAssertNil(quote)
    }

    func testProductionURLContainsOnlyPublicRateDimensions() throws {
        let url = try ECBRateHTTPClient().requestURL(
            currencies: ["THB", "HKD"],
            startDay: "2026-06-01",
            endDay: "2026-06-05"
        )
        let text = url.absoluteString

        XCTAssertTrue(text.contains("D.HKD+THB.EUR.SP00.A"))
        XCTAssertTrue(text.contains("startPeriod=2026-06-01"))
        XCTAssertTrue(text.contains("endPeriod=2026-06-05"))
        XCTAssertTrue(text.contains("format=csvdata"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("merchant"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("amount"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkimmedRateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
