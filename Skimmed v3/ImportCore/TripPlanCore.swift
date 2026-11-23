import Foundation

/// ImportCore — planned-trip audit records + statement-window math
///
/// A `PlannedTrip` is a user-created trip audit (Feature 1), additive to the
/// transaction-derived `Trip` the app already computes: derived trips keep
/// working untouched; planned trips carry their own persistence, coverage
/// checklist, and attached imports. Pure Codable value types so `swift test`
/// exercises them without the app target.
public struct PlannedTrip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var destinationCountry: String // ISO 3166
    public var label: String? // optional city/trip name, e.g. "Tokyo — cherry blossom"
    public var startDate: Date
    public var endDate: Date
    /// Cards the user says they used on this trip (free-text nicknames or
    /// existing card nicknames) — drives the coverage checklist.
    public var expectedCards: [String]
    /// ImportedCard ids whose statements were attached to this trip.
    public var attachedCardIDs: [UUID]
    /// ImportedTransaction ids committed through this trip's flow.
    public var transactionIDs: [UUID]
    public var createdAt: Date

    public init(id: UUID = UUID(), destinationCountry: String, label: String? = nil,
                startDate: Date, endDate: Date, expectedCards: [String] = [],
                attachedCardIDs: [UUID] = [], transactionIDs: [UUID] = [],
                createdAt: Date = Date()) {
        self.id = id
        self.destinationCountry = destinationCountry
        self.label = label
        self.startDate = startDate
        self.endDate = endDate
        self.expectedCards = expectedCards
        self.attachedCardIDs = attachedCardIDs
        self.transactionIDs = transactionIDs
        self.createdAt = createdAt
    }

    /// Audit lifecycle, derived — never stored, so it can't go stale.
    public enum Stage: Equatable, Sendable {
        case planning // no statements attached yet
        case partial // some expected cards still missing statements
        case complete // every expected card covered (or nothing pre-declared and ≥1 import)
    }

    public func stage(coveredCards: [String]) -> Stage {
        if attachedCardIDs.isEmpty { return .planning }
        let missing = TripPlanCore.missingCards(expected: expectedCards, covered: coveredCards)
        return missing.isEmpty ? .complete : .partial
    }
}

public enum TripPlanCore {

    /// Days after the trip ends that foreign charges can still settle/post.
    /// ponytail: fixed 7-day buffer; make issuer-specific if evidence demands.
    public static let settlementBufferDays = 7

    public struct StatementWindow: Equatable, Sendable {
        public let start: Date // trip start
        public let end: Date // trip end + settlement buffer
        /// First day of every calendar month the window touches — one entry
        /// per monthly statement the user needs.
        public let months: [Date]
    }

    /// The statement coverage window for a trip: charges post from the trip
    /// start through `settlementBufferDays` after return, so the user needs
    /// every monthly statement overlapping [start, end + buffer].
    public static func statementWindow(start: Date, end: Date, calendar: Calendar = .init(identifier: .gregorian)) -> StatementWindow {
        let windowEnd = calendar.date(byAdding: .day, value: settlementBufferDays, to: end) ?? end
        var months: [Date] = []
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        let last = calendar.date(from: calendar.dateComponents([.year, .month], from: windowEnd)) ?? windowEnd
        while cursor <= last {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return StatementWindow(start: start, end: windowEnd, months: months)
    }

    /// Plain-language sentence for the window (Feature 1 step 4).
    public static func windowSentence(_ window: StatementWindow, locale: Locale = Locale(identifier: "en_US")) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "MMM d"
        let monthFormatter = DateFormatter()
        monthFormatter.locale = locale
        monthFormatter.dateFormat = "MMMM yyyy"
        let monthList = window.months.map { monthFormatter.string(from: $0) }
        let monthsText: String
        switch monthList.count {
        case 0: monthsText = ""
        case 1: monthsText = monthList[0]
        default: monthsText = monthList.dropLast().joined(separator: ", ") + " and " + monthList[monthList.count - 1]
        }
        return "Charges can post until \(formatter.string(from: window.end)) — you'll need each card's \(monthsText) statement\(monthList.count == 1 ? "" : "s")."
    }

    /// Coverage checklist: expected card labels not yet covered by an
    /// attached import. Case/whitespace-insensitive.
    public static func missingCards(expected: [String], covered: [String]) -> [String] {
        let coveredSet = Set(covered.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return expected.filter { !coveredSet.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
    }
}

// MARK: - User card links (confirmed catalogue mappings)

/// A locally confirmed "(institution + last4) → exact card product" mapping
/// (the plan's `UserCard`). Reused on later imports so the user confirms a
/// card once. Never stores more than the last four digits.
public struct UserCardLink: Codable, Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case statementEvidence = "statement_evidence" // product named in the statement text
        case manual // user picked it from the catalogue
    }

    public var id: UUID
    public var institutionID: String
    public var last4: String?
    public var productID: String
    public var nickname: String?
    public var source: Source
    public var confirmedAt: Date

    public init(id: UUID = UUID(), institutionID: String, last4: String?,
                productID: String, nickname: String? = nil, source: Source,
                confirmedAt: Date = Date()) {
        self.id = id
        self.institutionID = institutionID
        self.last4 = last4
        self.productID = productID
        self.nickname = nickname
        self.source = source
        self.confirmedAt = confirmedAt
    }

    /// Rematch: an existing link applies to a new import when institution and
    /// last4 both match (last4-less links only rematch last4-less imports of
    /// the same institution).
    public static func match(institutionID: String, last4: String?, in links: [UserCardLink]) -> UserCardLink? {
        links.first { $0.institutionID == institutionID && $0.last4 == last4 }
    }
}

// MARK: - Advice evidence labels

/// Where a number/claim in trip advice comes from — every advice line is
/// labeled with one of these (Feature 4's honesty requirement).
public enum EvidenceLabel: String, Codable, Sendable {
    case observed // calculated from the user's uploaded statements
    case published // sourced from the verified catalogue
    case estimated // reference-rate-derived
    case insufficient = "insufficient_evidence" // can't support a conclusion

    public var display: String {
        switch self {
        case .observed: return "Observed"
        case .published: return "Published"
        case .estimated: return "Estimated"
        case .insufficient: return "Insufficient evidence"
        }
    }
}
