import Foundation

/// One grouped trip — pure value type, no app types.
public struct TripCore: Equatable {
    public let destinationCountry: String
    public let destinationCurrency: String
    public let startDate: Date
    public let endDate: Date? // nil while open (still within the quiet window of `asOf`)
    public let totalMarkup: Decimal // sum of POSITIVE markups only, per the plan

    public init(destinationCountry: String, destinationCurrency: String, startDate: Date, endDate: Date?, totalMarkup: Decimal) {
        self.destinationCountry = destinationCountry
        self.destinationCurrency = destinationCurrency
        self.startDate = startDate
        self.endDate = endDate
        self.totalMarkup = totalMarkup
    }
}

/// Input row for trip grouping: just what's needed, no app types.
public struct TripInputRow {
    public let date: Date
    public let currency: String
    public let markup: Decimal?

    public init(date: Date, currency: String, markup: Decimal?) {
        self.date = date
        self.currency = currency
        self.markup = markup
    }
}

public enum TripBuilderCore {
    public static let quietGapDays = 5
    public static let startWindowHours = 48

    /// Groups foreign transactions (`rows`, expected pre-filtered to
    /// `isForeign == true`) into trips: 2+ foreign transactions within 48h of
    /// each other START a trip; a started trip keeps absorbing subsequent
    /// foreign transactions as long as the gap since the last one is <= 5
    /// days ("close after 5 quiet days"), after which it closes and a new
    /// cluster starts fresh. A lone foreign transaction that never gets a
    /// second one within 48h does not become a trip. The final trip is left
    /// open (`endDate == nil`) only if `asOf` is still within the 5-day quiet
    /// window of its last transaction — otherwise it's closed at its last
    /// transaction date, same as any earlier trip.
    public static func build(rows: [TripInputRow], asOf: Date = Date()) -> [TripCore] {
        let sorted = rows.sorted { $0.date < $1.date }
        var trips: [TripCore] = []
        var cluster: [TripInputRow] = []
        var isTrip = false

        func flush(closeDate: Date?) {
            guard isTrip, !cluster.isEmpty else { cluster = []; isTrip = false; return }
            let currencies = cluster.map { $0.currency }
            let modalCurrency = modal(currencies)
            let country = CurrencyCountry.country(for: modalCurrency) ?? modalCurrency
            let totalMarkup = cluster.reduce(Decimal(0)) { sum, row in
                let m = row.markup ?? 0
                return sum + (m > 0 ? m : 0)
            }
            trips.append(TripCore(
                destinationCountry: country, destinationCurrency: modalCurrency,
                startDate: cluster.first!.date, endDate: closeDate, totalMarkup: totalMarkup
            ))
            cluster = []
            isTrip = false
        }

        for row in sorted {
            if cluster.isEmpty {
                cluster = [row]
                continue
            }
            let lastDate = cluster.last!.date
            let gapSeconds = row.date.timeIntervalSince(lastDate)
            if isTrip {
                if gapSeconds <= Double(quietGapDays) * 86_400 {
                    cluster.append(row)
                } else {
                    flush(closeDate: lastDate)
                    cluster = [row]
                }
            } else {
                if gapSeconds <= Double(startWindowHours) * 3_600 {
                    cluster.append(row)
                    isTrip = true
                } else {
                    // Lone transaction never joined by a second within 48h — discard, not a trip.
                    cluster = [row]
                }
            }
        }
        if isTrip {
            let lastDate = cluster.last!.date
            let quietSeconds = asOf.timeIntervalSince(lastDate)
            let closeDate: Date? = quietSeconds > Double(quietGapDays) * 86_400 ? lastDate : nil
            flush(closeDate: closeDate)
        }
        return trips
    }

    private static func modal(_ items: [String]) -> String {
        var counts: [String: Int] = [:]
        for item in items { counts[item, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key ?? items.first ?? ""
    }
}
