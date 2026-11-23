import Foundation

/// Minimal identity of an existing card, for matching purposes only — pure
/// value type, no app types (the app's `ImportedCard` wraps this).
public struct CardIdentity: Equatable {
    public let bank: String
    public let last4: String?

    public init(bank: String, last4: String?) {
        self.bank = bank
        self.last4 = last4
    }
}

/// Match outcome, indices into the `existing` array passed to `proposals`.
public enum MatchProposalCore: Equatable {
    case exact(Int) // bank + last4 both match an existing card
    case suggest(Int) // exactly one existing card of that bank (no/mismatched last4) — offer it
    case choose([Int]) // multiple existing cards of that bank — user must pick
    case createNew // no bank, or no existing card of that bank
}

public enum CardMatchCore {
    /// Order per the plan: exact bank+last4 match -> single-card-of-bank
    /// suggestion -> ambiguous choice -> create new.
    public static func proposals(bank: String?, last4: String?, existing: [CardIdentity]) -> MatchProposalCore {
        guard let bank, !bank.isEmpty else { return .createNew }
        let normalizedBank = bank.lowercased()
        let sameBankIndices = existing.indices.filter { existing[$0].bank.lowercased() == normalizedBank }

        if let last4, let exactIndex = sameBankIndices.first(where: { existing[$0].last4 == last4 }) {
            return .exact(exactIndex)
        }
        if sameBankIndices.count == 1 {
            return .suggest(sameBankIndices[0])
        }
        if sameBankIndices.count > 1 {
            return .choose(sameBankIndices)
        }
        return .createNew
    }
}
