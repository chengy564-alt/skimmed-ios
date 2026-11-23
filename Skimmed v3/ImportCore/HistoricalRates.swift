import Foundation

/// Where the comparison rate came from. ECB observations are date-specific;
/// the bundled table is deliberately surfaced as a provisional fallback.
nonisolated public enum HistoricalRateSource: String, Codable, Equatable {
    case ecb
    case bundledFallback
}

nonisolated public enum HistoricalCalculationStatus: String, Codable, Equatable {
    case verified
    case provisional
}

nonisolated public enum RateResolutionPolicy: Sendable {
    case allowFallback
    case verifiedOnly
}

/// A normalized one-day cross-rate request. Days use ISO `yyyy-MM-dd` so they
/// remain stable cache keys and match the ECB payload directly.
nonisolated public struct HistoricalRateRequest: Codable, Hashable {
    public let from: String
    public let to: String
    public let day: String

    public init(from: String, to: String, day: String) {
        self.from = from.uppercased()
        self.to = to.uppercased()
        self.day = day
    }
}

/// One ECB observation: units of `currency` obtainable for one euro.
nonisolated public struct HistoricalRateObservation: Codable, Equatable {
    public let currency: String
    public let day: String
    public let unitsPerEUR: Decimal

    public init(currency: String, day: String, unitsPerEUR: Decimal) {
        self.currency = currency.uppercased()
        self.day = day
        self.unitsPerEUR = unitsPerEUR
    }
}

nonisolated public struct HistoricalRateQuote: Codable, Equatable {
    public let request: HistoricalRateRequest
    public let observationDay: String
    /// One unit of `request.from`, expressed in `request.to`.
    public let rate: Decimal
    public let source: HistoricalRateSource
    public let status: HistoricalCalculationStatus

    public init(
        request: HistoricalRateRequest,
        observationDay: String,
        rate: Decimal,
        source: HistoricalRateSource,
        status: HistoricalCalculationStatus
    ) {
        self.request = request
        self.observationDay = observationDay
        self.rate = rate
        self.source = source
        self.status = status
    }

    public var observationDate: Date? {
        let components = observationDay.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: components[0], month: components[1], day: components[2]
        ))
    }
}

nonisolated public enum ECBRateCSVError: Error, Equatable {
    case unreadable
    case missingColumns
    case malformedRow(Int)
}

/// The valid observations plus enough diagnostics to decide whether a fetch
/// proves that a whole currency/date range was examined successfully. A
/// malformed row can be skipped without letting an older cached rate masquerade
/// as a verified quote for that malformed day.
nonisolated public struct ECBRateCSVParseResult: Equatable {
    public let observations: [HistoricalRateObservation]
    public let rejectedCurrencies: Set<String>
    public let hasUnattributedRejectedRows: Bool
}

/// Parser for the ECB Data Portal's `format=csvdata&detail=dataonly` response.
/// Header/schema failures reject the payload. Individual invalid series rows
/// are ignored so one damaged or unsupported row cannot discard valid rates
/// for every other requested currency.
nonisolated public enum ECBRateCSVParser {
    public static func parse(_ data: Data) throws -> [HistoricalRateObservation] {
        try parseResult(data).observations
    }

    public static func parseResult(_ data: Data) throws -> ECBRateCSVParseResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ECBRateCSVError.unreadable
        }
        let lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
        guard let headerLine = lines.first else { throw ECBRateCSVError.unreadable }
        let headers = fields(in: headerLine)
        guard
            let currencyIndex = headers.firstIndex(of: "CURRENCY"),
            let denominatorIndex = headers.firstIndex(of: "CURRENCY_DENOM"),
            let frequencyIndex = headers.firstIndex(of: "FREQ"),
            let typeIndex = headers.firstIndex(of: "EXR_TYPE"),
            let suffixIndex = headers.firstIndex(of: "EXR_SUFFIX"),
            let dayIndex = headers.firstIndex(of: "TIME_PERIOD"),
            let valueIndex = headers.firstIndex(of: "OBS_VALUE")
        else {
            throw ECBRateCSVError.missingColumns
        }

        var observations: [HistoricalRateObservation] = []
        var rejectedCurrencies: Set<String> = []
        var hasUnattributedRejectedRows = false
        for line in lines.dropFirst() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let row = fields(in: line)
            let requiredMax = [currencyIndex, denominatorIndex, frequencyIndex, typeIndex, suffixIndex, dayIndex, valueIndex].max() ?? 0
            guard row.indices.contains(requiredMax) else {
                recordRejection(
                    row: row,
                    currencyIndex: currencyIndex,
                    rejectedCurrencies: &rejectedCurrencies,
                    hasUnattributedRejectedRows: &hasUnattributedRejectedRows
                )
                continue
            }

            let currency = row[currencyIndex].uppercased()
            let day = row[dayIndex]
            guard
                currency.count == 3,
                currency.allSatisfy({ $0.isASCII && $0.isLetter }),
                row[denominatorIndex].uppercased() == "EUR",
                row[frequencyIndex].uppercased() == "D",
                row[typeIndex].uppercased() == "SP00",
                row[suffixIndex].uppercased() == "A",
                valid(day: day),
                let value = Decimal(string: row[valueIndex], locale: Locale(identifier: "en_US_POSIX")),
                value > 0
            else {
                recordRejection(
                    row: row,
                    currencyIndex: currencyIndex,
                    rejectedCurrencies: &rejectedCurrencies,
                    hasUnattributedRejectedRows: &hasUnattributedRejectedRows
                )
                continue
            }
            observations.append(HistoricalRateObservation(
                currency: currency,
                day: day,
                unitsPerEUR: value
            ))
        }
        return ECBRateCSVParseResult(
            observations: observations,
            rejectedCurrencies: rejectedCurrencies,
            hasUnattributedRejectedRows: hasUnattributedRejectedRows
        )
    }

    private static func recordRejection(
        row: [String],
        currencyIndex: Int,
        rejectedCurrencies: inout Set<String>,
        hasUnattributedRejectedRows: inout Bool
    ) {
        guard row.indices.contains(currencyIndex) else {
            hasUnattributedRejectedRows = true
            return
        }
        let currency = row[currencyIndex].uppercased()
        guard currency.count == 3,
              currency.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            hasUnattributedRejectedRows = true
            return
        }
        rejectedCurrencies.insert(currency)
    }

    private static func fields(in line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func valid(day: String) -> Bool {
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

/// Mergeable on-device corpus of public ECB observations.
nonisolated public struct HistoricalRateBook: Codable, Equatable {
    public private(set) var observations: [HistoricalRateObservation]

    public init(observations: [HistoricalRateObservation] = []) {
        self.observations = []
        merge(observations)
    }

    private enum CodingKeys: String, CodingKey {
        case observations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([HistoricalRateObservation].self, forKey: .observations)
        self.observations = []
        merge(decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observations, forKey: .observations)
    }

    public mutating func merge(_ incoming: [HistoricalRateObservation]) {
        var byKey: [String: HistoricalRateObservation] = [:]
        for observation in observations where Self.valid(observation) {
            byKey[Self.key(currency: observation.currency, day: observation.day)] = observation
        }
        for observation in incoming where Self.valid(observation) {
            byKey[Self.key(currency: observation.currency, day: observation.day)] = observation
        }
        observations = byKey.values.sorted {
            $0.day == $1.day ? $0.currency < $1.currency : $0.day < $1.day
        }
    }

    public func quote(
        for request: HistoricalRateRequest,
        maximumLookbackDays: Int = 7
    ) -> HistoricalRateQuote? {
        guard let requestedDate = Self.date(from: request.day) else { return nil }
        if request.from == request.to {
            return HistoricalRateQuote(
                request: request,
                observationDay: request.day,
                rate: 1,
                source: .ecb,
                status: .verified
            )
        }

        let calendar = Self.calendar
        for offset in 0...max(0, maximumLookbackDays) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: requestedDate) else { continue }
            let day = Self.day(from: date)
            guard
                let fromUnits = unitsPerEUR(currency: request.from, day: day),
                let toUnits = unitsPerEUR(currency: request.to, day: day),
                fromUnits > 0,
                toUnits > 0
            else { continue }
            return HistoricalRateQuote(
                request: request,
                observationDay: day,
                rate: toUnits / fromUnits,
                source: .ecb,
                status: .verified
            )
        }
        return nil
    }

    private func unitsPerEUR(currency: String, day: String) -> Decimal? {
        if currency == "EUR" { return 1 }
        return observations.first {
            $0.currency == currency && $0.day == day
        }?.unitsPerEUR
    }

    private static func key(currency: String, day: String) -> String {
        "\(currency)|\(day)"
    }

    private static func valid(_ observation: HistoricalRateObservation) -> Bool {
        observation.currency.count == 3
            && observation.currency.allSatisfy { $0.isASCII && $0.isLetter }
            && date(from: observation.day) != nil
            && observation.unitsPerEUR > 0
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func date(from day: String) -> Date? {
        let components = day.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: components[0], month: components[1], day: components[2]
        ))
    }

    private static func day(from date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
