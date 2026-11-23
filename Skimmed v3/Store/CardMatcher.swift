import Foundation

/// App-facing wrapper over `CardMatchCore` (ImportCore's pure, unit-tested
/// matching logic). Operates on real `ImportedCard`s so B4's UI can act on
/// the proposal directly.
enum MatchProposal: Equatable {
    case exact(ImportedCard)
    case suggest(ImportedCard)
    case choose([ImportedCard])
    case createNew
}

enum CardMatcher {
    /// Order (per the plan): bank+last4 exact match -> single card of that
    /// bank suggested -> multiple cards of that bank, user chooses -> no
    /// match, create a new card.
    static func proposals(bank: String?, last4: String?, existing: [ImportedCard]) -> MatchProposal {
        let identities = existing.map { CardIdentity(bank: $0.bank, last4: $0.last4) }
        switch CardMatchCore.proposals(bank: bank, last4: last4, existing: identities) {
        case .exact(let index):
            return .exact(existing[index])
        case .suggest(let index):
            return .suggest(existing[index])
        case .choose(let indices):
            return .choose(indices.map { existing[$0] })
        case .createNew:
            return .createNew
        }
    }
}
