import SwiftUI

/// "Which card should I use?" — the standing-at-the-register lookup. Pick a
/// destination, instantly see your own cards ranked by what they actually
/// cost you there. Rankings come straight from `AppStore.cardRankings`
/// (median observed markup from one comparable evidence tier); destinations without enough data
/// say so honestly instead of pretending to rank.
struct WhichCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appStore = AppStore.shared
    @AppStorage("profile.destinations") private var storedDestinations: String = ""

    @State private var selectedCurrency: String? = nil

    /// Currencies worth offering: every currency we can actually rank, plus
    /// the user's chosen destinations (which may not have data yet — those
    /// get the honest empty state, not silence).
    private var options: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for ranking in appStore.cardRankings where seen.insert(ranking.destinationCurrency).inserted {
            out.append(ranking.destinationCurrency)
        }
        for dest in storedDestinations.split(separator: ",").map(String.init) {
            if let info = Derive.destinationInfo(dest), seen.insert(info.currency).inserted {
                out.append(info.currency)
            }
        }
        return out
    }

    private func label(for currency: String) -> String {
        for destination in storedDestinations.split(separator: ",").map(String.init) {
            if let info = Derive.destinationInfo(destination), info.currency == currency {
                return "\(Derive.flag(info.country)) \(destination)"
            }
        }
        return currency
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Which card should I use?")
                        .font(.app(18, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.cream)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.06), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(PressStyle(scale: 0.9))
                }

                if options.isEmpty {
                    emptyState
                } else {
                    Text("WHERE ARE YOU PAYING?")
                        .font(.app(10, weight: .semibold))
                        .kerning(1.4)
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 20)

                    FlowLayout(spacing: 8) {
                        ForEach(options, id: \.self) { currency in
                            Chip(label: label(for: currency), isOn: selectedCurrency == currency) {
                                selectedCurrency = currency
                            }
                        }
                    }
                    .padding(.top, 12)

                    ScrollView(showsIndicators: false) {
                        if let currency = selectedCurrency {
                            resultCard(for: currency)
                                .padding(.top, 20)
                                .id(currency) // fresh identity → entrance replays per pick
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: selectedCurrency)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // No sheet-level selection haptic — each Chip already ticks on
        // toggle, and stacking the two reads as one mushy double-buzz.
        .onAppear {
            if selectedCurrency == nil { selectedCurrency = options.first }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultCard(for currency: String) -> some View {
        if let ranking = appStore.cardRankings.first(where: { $0.destinationCurrency == currency }) {
            let tiedBestCount = ranking.rankedAccounts.filter(\.isTiedBest).count
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ranking.rankedAccounts.enumerated()), id: \.offset) { index, ranked in
                    rankedRow(
                        index: index, ranked: ranked,
                        isBest: ranked.isTiedBest,
                        isSoleWinner: ranked.isTiedBest && tiedBestCount == 1,
                        currency: currency,
                        evidenceTier: ranking.evidenceTier
                    )
                }

                Text(evidenceCopy(for: ranking))
                    .font(.app(10.5))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
            }
            .padding(16)
            .surfaceCard(cornerRadius: 18)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not enough data for \(currency) yet")
                    .font(.app(13, weight: .bold))
                    .foregroundStyle(Theme.cream)
                Text("We rank cards by what they actually charged you — import statements from at least two cards with \(currency) charges and the ranking appears here.")
                    .font(.app(11.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                HStack {
                    AddStatementPill()
                    Spacer()
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .surfaceCard(cornerRadius: 18)
        }
    }

    private func rankedRow(
        index: Int,
        ranked: RankedAccount,
        isBest: Bool,
        isSoleWinner: Bool,
        currency: String,
        evidenceTier: RecommendationEvidenceTier
    ) -> some View {
        let account = appStore.linkedAccounts.first { $0.id == ranked.linkedAccountId }
        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.app(11, weight: .bold))
                .foregroundStyle(isBest ? Theme.onAccent : Theme.muted)
                .frame(width: 24, height: 24)
                .background(isBest ? Theme.accent : Color.white.opacity(0.1), in: Circle())

            BankMark(bank: account?.institutionName ?? "—", size: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(account?.displayName ?? "Unknown card")
                    .font(.app(13, weight: .bold))
                    .foregroundStyle(Theme.cream)
                Text(rankingSubtitle(
                    markupPct: ranked.markupPct,
                    currency: currency,
                    evidenceTier: evidenceTier
                ))
                    .font(.app(10.5))
                    .foregroundStyle(Theme.muted)
                RateEvidenceBadge(
                    text: ranked.confidence.evidenceLabel,
                    provisional: ranked.confidence == .limited
                )
            }

            Spacer(minLength: 8)

            if isBest {
                Text(winnerLabel(
                    evidenceTier: evidenceTier,
                    isSoleWinner: isSoleWinner
                ))
                    .font(.app(8.5, weight: .heavy))
                    .kerning(0.5)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(
            isBest ? Theme.accent.opacity(0.1) : Color.white.opacity(0.02),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isBest ? Theme.accent.opacity(0.6) : Color.white.opacity(0.05),
                    lineWidth: 1
                )
        )
    }

    private func winnerLabel(
        evidenceTier: RecommendationEvidenceTier,
        isSoleWinner: Bool
    ) -> String {
        switch evidenceTier {
        case .verifiedDestination:
            return isSoleWinner ? "BEST OBSERVED" : "JOINT BEST"
        case .verifiedCrossCurrency:
            return isSoleWinner ? "LIMITED PICK" : "JOINT GUIDE"
        case .provisionalDestination:
            return isSoleWinner ? "PROVISIONAL" : "JOINT ESTIMATE"
        }
    }

    private func rankingSubtitle(
        markupPct: Double,
        currency: String,
        evidenceTier: RecommendationEvidenceTier
    ) -> String {
        switch evidenceTier {
        case .verifiedDestination:
            return "~\(Derive.fmtPct(markupPct)) verified markup on \(currency)"
        case .verifiedCrossCurrency:
            return "~\(Derive.fmtPct(markupPct)) across verified FX history elsewhere"
        case .provisionalDestination:
            return "~\(Derive.fmtPct(markupPct)) provisional markup on \(currency)"
        }
    }

    private func evidenceCopy(for ranking: CardRanking) -> String {
        switch ranking.evidenceTier {
        case .verifiedDestination:
            return "Ranked by each owned card's median verified markup in \(ranking.destinationCurrency)."
        case .verifiedCrossCurrency:
            return "Limited cross-currency view, based on each owned card's verified FX history in other currencies."
        case .provisionalDestination:
            return "Provisional ranking from offline reference estimates in \(ranking.destinationCurrency); it updates automatically."
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No card data yet")
                .font(.app(13, weight: .bold))
                .foregroundStyle(Theme.cream)
            Text("Import statements from the cards you travel with, and Skimmed ranks them by what each one actually costs you abroad.")
                .font(.app(11.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
            HStack {
                AddStatementPill()
                Spacer()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .surfaceCard(cornerRadius: 18)
        .padding(.top, 20)
    }
}
