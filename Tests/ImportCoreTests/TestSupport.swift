import Foundation
import XCTest
@testable import ImportCore

/// Shared fixture + date helpers. Fixtures are synthetic statements shaped
/// like each bank's real CSV export — no real account data anywhere.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).csv"])
        }
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

/// Midnight UTC — matches CSVImporter's parsing timezone.
func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

func dec(_ s: String) -> Decimal {
    Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))!
}
