import Foundation

/// App-facing wrapper over `TripBuilderCore` (ImportCore's pure, unit-tested
/// grouping logic). Converts foreign `ImportedTransaction`s into the app's
/// `Trip` type.
enum TripBuilder {
    static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// - Parameters:
    ///   - transactions: real-mode transactions (foreign and domestic mixed
    ///     in is fine — only `isForeign == true` rows are grouped).
    ///   - userId: real mode doesn't yet manage multiple user profiles; a
    ///     stable placeholder id fills the `userId` slot the same way
    ///     the removed seed data did.
    ///   - asOf: "now", for deciding whether the most recent trip is still
    ///     open (matches `TripBuilderCore.build`'s default).
    static func build(from transactions: [ImportedTransaction], userId: String, asOf: Date = Date()) -> [Trip] {
        let foreignRows = transactions.filter { $0.isForeign }
        let inputRows = foreignRows.map {
            TripInputRow(date: $0.txDate, currency: $0.billedCurrency, markup: $0.markupAmount)
        }
        let cores = TripBuilderCore.build(rows: inputRows, asOf: asOf)
        return cores.enumerated().map { index, core in
            Trip(
                id: "trip_import_\(index)",
                userId: userId,
                destinationCountry: core.destinationCountry,
                destinationCurrency: core.destinationCurrency,
                startDate: isoDateFormatter.string(from: core.startDate),
                endDate: core.endDate.map { isoDateFormatter.string(from: $0) },
                totalMarkupThisTrip: Derive.round2(NSDecimalNumber(decimal: core.totalMarkup).doubleValue)
            )
        }
    }
}
