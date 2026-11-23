import Foundation

nonisolated public protocol ECBRateFetching: Sendable {
    func fetch(
        currencies: Set<String>,
        startDay: String,
        endDay: String
    ) async throws -> Data
}

nonisolated public enum ECBRateHTTPError: Error, Equatable {
    case invalidCurrency(String)
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
}

/// Production client for public ECB statistics. Requests contain only ISO
/// currencies and a date range — never statement or user data.
nonisolated public final class ECBRateHTTPClient: ECBRateFetching, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func requestURL(
        currencies: Set<String>,
        startDay: String,
        endDay: String
    ) throws -> URL {
        let normalized = try currencies.map { raw -> String in
            let currency = raw.uppercased()
            guard currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                throw ECBRateHTTPError.invalidCurrency(raw)
            }
            return currency
        }.sorted()
        guard !normalized.isEmpty else { throw ECBRateHTTPError.invalidURL }

        let series = normalized.joined(separator: "+")
        var components = URLComponents(string:
            "https://data-api.ecb.europa.eu/service/data/EXR/D.\(series).EUR.SP00.A"
        )
        components?.queryItems = [
            URLQueryItem(name: "startPeriod", value: startDay),
            URLQueryItem(name: "endPeriod", value: endDay),
            URLQueryItem(name: "format", value: "csvdata"),
            URLQueryItem(name: "detail", value: "dataonly"),
        ]
        guard let url = components?.url else { throw ECBRateHTTPError.invalidURL }
        return url
    }

    public func fetch(
        currencies: Set<String>,
        startDay: String,
        endDay: String
    ) async throws -> Data {
        let url = try requestURL(currencies: currencies, startDay: startDay, endDay: endDay)
        var request = URLRequest(url: url)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ECBRateHTTPError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw ECBRateHTTPError.httpStatus(http.statusCode)
        }
        return data
    }
}

/// Coordinates the public on-device cache, ECB fetches, and explicit bundled
/// fallback. Fallback quotes are returned to callers but never written into the
/// verified-observation cache.
public actor HistoricalRateRepository {
    private struct FetchCoverage: Codable, Equatable {
        let currencies: Set<String>
        let startDay: String
        let endDay: String

        func contains(currency: String, day: String) -> Bool {
            isValid && currencies.contains(currency) && startDay <= day && day <= endDay
        }

        var isValid: Bool {
            !currencies.isEmpty
                && currencies.allSatisfy(Self.validCurrency)
                && Self.validDay(startDay)
                && Self.validDay(endDay)
                && startDay <= endDay
        }

        private static func validCurrency(_ currency: String) -> Bool {
            currency.count == 3 && currency.allSatisfy { $0.isASCII && $0.isLetter }
        }

        private static func validDay(_ day: String) -> Bool {
            guard day.count == 10 else { return false }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: day) != nil
        }
    }

    private let cacheURL: URL
    private let coverageURL: URL
    private let fetcher: any ECBRateFetching
    private var book: HistoricalRateBook
    private var coverage: [FetchCoverage]

    public init(cacheURL: URL, fetcher: any ECBRateFetching = ECBRateHTTPClient()) {
        self.cacheURL = cacheURL
        // v2 records only exact requested-day confirmations (plus known
        // weekends). Older range-wide coverage was too broad and is ignored.
        self.coverageURL = cacheURL.appendingPathExtension("coverage-v2")
        self.fetcher = fetcher
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(HistoricalRateBook.self, from: data) {
            self.book = decoded
        } else {
            self.book = HistoricalRateBook()
        }
        if let data = try? Data(contentsOf: coverageURL),
           let decoded = try? JSONDecoder().decode([FetchCoverage].self, from: data) {
            self.coverage = decoded.filter(\.isValid)
        } else {
            self.coverage = []
        }
    }

    public func resolve(
        _ requests: Set<HistoricalRateRequest>,
        policy: RateResolutionPolicy = .allowFallback
    ) async -> [HistoricalRateRequest: HistoricalRateQuote] {
        guard !requests.isEmpty else { return [:] }

        var resolved = reusableVerifiedQuotes(for: requests)
        let missing = requests.subtracting(resolved.keys)
        if !missing.isEmpty {
            await fetchAndMerge(for: missing)
            resolved.merge(reusableVerifiedQuotes(for: missing)) { _, new in new }
        }

        if case .allowFallback = policy {
            for request in requests where resolved[request] == nil {
                resolved[request] = RateTable.fallbackQuote(for: request)
            }
        }
        return resolved
    }

    private func reusableVerifiedQuotes(
        for requests: Set<HistoricalRateRequest>
    ) -> [HistoricalRateRequest: HistoricalRateQuote] {
        var result: [HistoricalRateRequest: HistoricalRateQuote] = [:]
        for request in requests {
            if let quote = book.quote(for: request),
               quote.observationDay == request.day || hasCompleteCoverage(for: request) {
                result[request] = quote
            }
        }
        return result
    }

    private func hasCompleteCoverage(for request: HistoricalRateRequest) -> Bool {
        Set([request.from, request.to])
            .subtracting(["EUR"])
            .allSatisfy { currency in
                coverage.contains { $0.contains(currency: currency, day: request.day) }
            }
    }

    private func fetchAndMerge(for requests: Set<HistoricalRateRequest>) async {
        let days = requests.map(\.day).sorted()
        guard
            let first = days.first,
            let last = days.last,
            let startDay = Self.adding(days: -7, to: first)
        else { return }
        let currencies = Set(requests.flatMap { [$0.from, $0.to] }).subtracting(["EUR"])
        guard !currencies.isEmpty else { return }

        do {
            let data = try await fetcher.fetch(
                currencies: currencies,
                startDay: startDay,
                endDay: last
            )
            let parsed = try ECBRateCSVParser.parseResult(data)
            let inRange = parsed.observations.filter {
                startDay <= $0.day && $0.day <= last
            }
            guard inRange.count == parsed.observations.count else { return }
            book.merge(inRange)
            await confirmMissingWeekdayObservations(for: requests)
            await confirmMissingWeekendObservations(for: requests)
            try persist()
        } catch {
            // A network, HTTP, or payload failure is handled by the resolution
            // policy: callers either receive an explicit fallback or no quote.
        }
    }

    /// A clean exact-day response distinguishes a genuine ECB holiday/no-rate
    /// day from a valid-looking but truncated expanded CSV. Only that exact
    /// confirmation is allowed to authorize a previous weekday observation.
    private func confirmMissingWeekdayObservations(
        for requests: Set<HistoricalRateRequest>
    ) async {
        var currenciesByDay: [String: Set<String>] = [:]
        for request in requests where !Self.isWeekend(request.day) {
            guard let quote = book.quote(for: request),
                  quote.observationDay != request.day,
                  !hasCompleteCoverage(for: request) else { continue }
            currenciesByDay[request.day, default: []]
                .formUnion(Set([request.from, request.to]).subtracting(["EUR"]))
        }

        for day in currenciesByDay.keys.sorted() {
            guard let requestedCurrencies = currenciesByDay[day],
                  !requestedCurrencies.isEmpty else { continue }
            do {
                let data = try await fetcher.fetch(
                    currencies: requestedCurrencies,
                    startDay: day,
                    endDay: day
                )
                let parsed = try ECBRateCSVParser.parseResult(data)
                guard !parsed.hasUnattributedRejectedRows,
                      parsed.observations.allSatisfy({ $0.day == day }) else { continue }
                book.merge(parsed.observations)
                let observedCurrencies = Set(parsed.observations.map(\.currency))
                let safelyCovered = (parsed.observations.isEmpty
                    ? requestedCurrencies
                    : requestedCurrencies.intersection(observedCurrencies))
                    .subtracting(parsed.rejectedCurrencies)
                guard !safelyCovered.isEmpty else { continue }
                coverage.append(FetchCoverage(
                    currencies: safelyCovered,
                    startDay: day,
                    endDay: day
                ))
            } catch {
                // Without a clean exact-day response, the older observation
                // stays unverified and the caller receives fallback/no quote.
            }
        }
    }

    /// Weekend requests verify the nearest prior business day directly. A
    /// clean empty response means an ECB holiday, so the check walks backward
    /// (within the same seven-day quote window). Partial or wrong-day data
    /// cannot authorize a still-older cached observation.
    private func confirmMissingWeekendObservations(
        for requests: Set<HistoricalRateRequest>
    ) async {
        for request in requests where Self.isWeekend(request.day) {
            guard let existingQuote = book.quote(for: request),
                  existingQuote.observationDay != request.day,
                  !hasCompleteCoverage(for: request),
                  let lowerBound = Self.adding(days: -7, to: request.day),
                  var candidate = Self.previousBusinessDay(before: request.day)
            else { continue }

            let requiredCurrencies = Set([request.from, request.to])
                .subtracting(["EUR"])
            guard !requiredCurrencies.isEmpty else { continue }

            while candidate >= lowerBound {
                do {
                    let data = try await fetcher.fetch(
                        currencies: requiredCurrencies,
                        startDay: candidate,
                        endDay: candidate
                    )
                    let parsed = try ECBRateCSVParser.parseResult(data)
                    guard !parsed.hasUnattributedRejectedRows,
                          parsed.observations.allSatisfy({ $0.day == candidate })
                    else { break }

                    if parsed.observations.isEmpty {
                        guard let previous = Self.previousBusinessDay(before: candidate) else {
                            break
                        }
                        candidate = previous
                        continue
                    }

                    let observedCurrencies = Set(parsed.observations.map(\.currency))
                        .subtracting(parsed.rejectedCurrencies)
                    guard requiredCurrencies.isSubset(of: observedCurrencies) else { break }
                    book.merge(parsed.observations)
                    coverage.append(FetchCoverage(
                        currencies: requiredCurrencies,
                        startDay: request.day,
                        endDay: request.day
                    ))
                    break
                } catch {
                    break
                }
            }
        }
    }

    private func persist() throws {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(book)
        try data.write(to: cacheURL, options: [.atomic])
        let coverageData = try JSONEncoder().encode(coverage)
        try coverageData.write(to: coverageURL, options: [.atomic])
    }

    private static func adding(days: Int, to day: String) -> String? {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard
            let date = calendar.date(from: DateComponents(
                year: pieces[0], month: pieces[1], day: pieces[2]
            )),
            let adjusted = calendar.date(byAdding: .day, value: days, to: date)
        else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: adjusted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func isWeekend(_ day: String) -> Bool {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(
            year: pieces[0], month: pieces[1], day: pieces[2]
        )) else { return false }
        return calendar.isDateInWeekend(date)
    }

    private static func previousBusinessDay(before day: String) -> String? {
        guard var candidate = adding(days: -1, to: day) else { return nil }
        while isWeekend(candidate) {
            guard let previous = adding(days: -1, to: candidate) else { return nil }
            candidate = previous
        }
        return candidate
    }
}
