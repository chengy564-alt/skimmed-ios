import SwiftUI

/// Full-screen search over the mock dataset. Suggestion chips before you
/// type (recent merchants + statement currencies); as you type, matching
/// transactions animate in per keystroke. Presented as a full-screen cover
/// from Home's magnifying-glass button.
struct SearchOverlay: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appStore = AppStore.shared

    @State private var query = ""
    @State private var appeared = false
    @State private var selectedTx: Transaction? = nil
    @FocusState private var focused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Derived from the typed mock dataset, never hardcoded

    /// Six most recent distinct merchants.
    private var recentMerchants: [String] {
        var seen = Set<String>()
        return Array(
            appStore.transactions
                .sorted { $0.txDate > $1.txDate }
                .compactMap { seen.insert($0.merchantName).inserted ? $0.merchantName : nil }
                .prefix(6)
        )
    }

    /// Distinct statement currencies. A currency is never presented as proof
    /// of the merchant's country.
    private var currencyChips: [String] {
        var seen = Set<String>()
        return appStore.transactions.compactMap { tx in
            seen.insert(tx.billedCurrency).inserted ? tx.billedCurrency : nil
        }
    }

    private var results: [Transaction] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return appStore.transactions
            .filter { tx in
                tx.merchantName.localizedCaseInsensitiveContains(q)
                    || tx.billedCurrency.localizedCaseInsensitiveContains(q)
            }
            .sorted { $0.txDate > $1.txDate }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            AppBackdrop()

            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                ScrollView(showsIndicators: false) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        suggestions
                            .padding(.top, 24)
                    } else {
                        resultsList
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 16)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { appeared = true }
            focused = true
        }
        .sheet(item: $selectedTx) { tx in
            TxDetailSheet(tx: tx)
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)

            TextField(
                "",
                text: $query,
                prompt: Text("Search merchants or currencies")
                    .foregroundStyle(Theme.muted)
            )
            .font(.app(14, weight: .semibold))
            .foregroundStyle(Theme.cream)
            .focused($focused)
            .submitLabel(.search)
            .autocorrectionDisabled()

            if !query.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(PressStyle(scale: 0.9))
            }

            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.app(12, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(PressStyle(scale: 0.94))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .glass(in: Capsule())
    }

    // MARK: - Suggestions (pre-typing)

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT MERCHANTS")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)

            FlowLayout(spacing: 8) {
                ForEach(recentMerchants, id: \.self) { merchant in
                    suggestionChip(merchant) { query = merchant }
                }
            }
            .padding(.top, 12)

            Text("CURRENCIES")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)
                .padding(.top, 28)

            FlowLayout(spacing: 8) {
                ForEach(currencyChips, id: \.self) { chip in
                    suggestionChip(chip) {
                        query = chip
                    }
                }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { action() }
        } label: {
            Text(label)
                .font(.app(12, weight: .semibold))
                .foregroundStyle(Theme.cream)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(PressStyle(scale: 0.95))
    }

    // MARK: - Results (typing)

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.muted.opacity(0.6))
                    Text("Nothing skimmed matches that")
                        .font(.app(12))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                Text("\(results.count) charges · \(Derive.fmtMoney(Derive.totalMarkup(results))) markup")
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Theme.accent)

                VStack(spacing: 14) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, tx in
                        TxRow(tx: tx, blurAmount: false, onTap: { selectedTx = tx })
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                            .animation(
                                .spring(response: 0.35, dampingFraction: 0.8)
                                    .delay(Double(index) * 0.04),
                                value: query
                            )
                    }
                }
                .padding(20)
                .surfaceCard()
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: results.count)
        .padding(.bottom, 40)
    }
}
