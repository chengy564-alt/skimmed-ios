import SwiftUI

/// Cards — the Wallet-style stack of linked cards, in Skimmed's own skin.
/// Cards fan in on load, overlapping like a hand of cards (worst offender in
/// front). Tapping one brings it forward with a spring morph
/// (matchedGeometryEffect), reveals its loss stats, and compresses the rest
/// into a mini stack below; drag the focused card for a subtle 3D tilt.
/// Card artwork is built from each bank's BankMark brand color. Reads
/// `AppStore` (derived from imported statements); with nothing imported it
/// shows an empty state with the import CTA.
struct CardsView: View {

    @ObservedObject private var appStore = AppStore.shared
    @ObservedObject private var motion = MotionManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedId: String? = nil
    @State private var appeared = false
    @State private var tilt: CGSize = .zero
    @State private var confirmDeleteId: String? = nil
    @State private var showEmptyStateImport = false

    @Namespace private var cardSpace

    // MARK: - Derived from AppStore

    /// Back-to-front: ascending loss, so the worst offender lands on top.
    private var ordered: [LinkedAccount] {
        appStore.linkedAccounts.sorted {
            Derive.markupForAccount(appStore.transactions, accountId: $0.id)
                < Derive.markupForAccount(appStore.transactions, accountId: $1.id)
        }
    }

    private var selectedAccount: LinkedAccount? {
        ordered.first { $0.id == selectedId }
    }

    private var totalLoss: Double { appStore.revealSnapshot.totalLossAmount }

    private func loss(_ account: LinkedAccount) -> Double {
        Derive.markupForAccount(appStore.transactions, accountId: account.id)
    }

    private func txCount(_ account: LinkedAccount) -> Int {
        appStore.transactions.filter { $0.linkedAccountId == account.id }.count
    }

    private func markupPct(_ account: LinkedAccount) -> Double? {
        appStore.cardRankings.first?.rankedAccounts
            .first { $0.linkedAccountId == account.id }?.markupPct
    }

    /// The underlying `ImportedCard` behind a `LinkedAccount` row (for
    /// last-imported date + a confidence hint `Transaction` doesn't carry).
    private func importedCard(for account: LinkedAccount) -> ImportedCard? {
        appStore.cards.first { $0.id.uuidString == account.id }
    }

    private func confidenceHint(_ card: ImportedCard) -> String? {
        let rows = appStore.calculationTransactions.filter { $0.cardID == card.id }
        guard !rows.isEmpty else { return nil }
        let unpriced = rows.filter { $0.confidence == .unableToCalculate }.count
        guard unpriced > 0 else { return nil }
        return "\(unpriced) charge\(unpriced == 1 ? "" : "s") couldn't be priced"
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let cardW = geo.size.width - 32
            let cardH = cardW / 1.586 // real card proportions (ISO/IEC 7810)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 12)

                    if ordered.isEmpty {
                        emptyState
                            .padding(.top, 28)
                    } else {
                        Group {
                            if let account = selectedAccount {
                                focusedLayout(account, cardW: cardW, cardH: cardH)
                            } else {
                                fanLayout(cardW: cardW, cardH: cardH)
                            }
                        }
                        .padding(.top, 28)

                        Text(selectedId == nil
                            ? "Tap a card to inspect it"
                            : "Tap the card again to see all")
                            .font(.app(11))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 140) // room for the floating nav
            }
        }
        .sensoryFeedback(.selection, trigger: selectedId)
        .onAppear {
            appeared = true
            if !reduceMotion { motion.start() }
        }
        .onDisappear {
            if !reduceMotion { motion.stop() }
        }
        .confirmationDialog(
            "Delete this card?",
            isPresented: Binding(
                get: { confirmDeleteId != nil },
                set: { if !$0 { confirmDeleteId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete card and its charges", role: .destructive) {
                if let id = confirmDeleteId, let card = appStore.cards.first(where: { $0.id.uuidString == id }) {
                    if selectedId == id { selectedId = nil }
                    appStore.deleteCard(card)
                }
                confirmDeleteId = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteId = nil }
        } message: {
            Text("This removes the card and every charge imported from it. Your other cards are unaffected.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your")
                    .font(.app(27, weight: .heavy))
                    .foregroundStyle(Theme.cream)
                Text("Cards")
                    .font(.app(27, weight: .heavy))
                    .foregroundStyle(Theme.cream)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 8) {
                    AddStatementPill()
                    Text("\(ordered.count) LINKED")
                        .font(.app(9.5, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                }
                Text("From your statements")
                    .font(.app(10))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - Empty state (nothing imported yet)

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "creditcard")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accent)

            Text("No cards yet")
                .font(.app(22, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .padding(.top, 14)

            Text("Import a statement and each card it belongs to shows up here, ranked by how much it skims.")
                .font(.app(12.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 8)

            PrimaryButton(title: "Import a statement", leadingIcon: "lock.fill", trailingIcon: nil) {
                showEmptyStateImport = true
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .surfaceCard(cornerRadius: 20)
        .fullScreenCover(isPresented: $showEmptyStateImport) {
            ImportEntrySheet { showEmptyStateImport = false }
        }
    }

    // MARK: - Fanned stack (nothing selected)

    private func fanLayout(cardW: CGFloat, cardH: CGFloat) -> some View {
        let peek: CGFloat = 78
        return ZStack(alignment: .top) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, account in
                card(account, w: cardW, h: cardH)
                    .offset(y: CGFloat(index) * peek)
                    .matchedGeometryEffect(id: account.id, in: cardSpace)
                    // Lighter gyro parallax on the fan — cards deeper in the
                    // stack lean a touch more, giving the fan real depth.
                    .rotation3DEffect(
                        .degrees(gyroY * (0.35 + 0.12 * Double(index))),
                        axis: (x: 0, y: 1, z: 0), perspective: 0.7
                    )
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: gyroY)
                    .zIndex(Double(index))
                    .onTapGesture { select(account.id) }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 48)
                    .animation(
                        .spring(response: 0.6, dampingFraction: 0.8)
                            .delay(0.08 * Double(index)),
                        value: appeared
                    )
                    .contextMenu {
                        if importedCard(for: account) != nil {
                            Button("Delete card", role: .destructive) {
                                confirmDeleteId = account.id
                            }
                        }
                    }
            }
        }
        .frame(height: cardH + peek * CGFloat(max(0, ordered.count - 1)), alignment: .top)
    }

    // MARK: - Focused card + loss stats + mini stack

    private func focusedLayout(_ account: LinkedAccount, cardW: CGFloat, cardH: CGFloat) -> some View {
        let others = ordered.filter { $0.id != account.id }
        let peek: CGFloat = 54
        return VStack(spacing: 20) {
            card(account, w: cardW, h: cardH, isFocused: true)
                .matchedGeometryEffect(id: account.id, in: cardSpace)
                .rotation3DEffect(.degrees(tiltX + gyroX), axis: (x: 1, y: 0, z: 0), perspective: 0.7)
                .rotation3DEffect(.degrees(tiltY + gyroY), axis: (x: 0, y: 1, z: 0), perspective: 0.7)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: gyroX)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: gyroY)
                .gesture(tiltGesture)
                .onTapGesture { deselect() }
                .zIndex(3)
                .id("focused-\(account.id)")
                .contextMenu {
                    if importedCard(for: account) != nil {
                        Button("Delete card", role: .destructive) {
                            confirmDeleteId = account.id
                        }
                    }
                }

            statsPanel(account)
                .id(account.id) // fresh identity per card → count-ups replay
                .transition(.opacity.combined(with: .offset(y: 16)))

            Text("OTHER CARDS")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)

            ZStack(alignment: .top) {
                ForEach(Array(others.enumerated()), id: \.element.id) { index, other in
                    card(other, w: cardW, h: cardH)
                        .matchedGeometryEffect(id: other.id, in: cardSpace)
                        .scaleEffect(0.95, anchor: .top)
                        .offset(y: CGFloat(index) * peek)
                        .zIndex(Double(index))
                        .opacity(0.88)
                        .onTapGesture { select(other.id) }
                }
            }
            .frame(height: cardH + peek * CGFloat(max(0, others.count - 1)), alignment: .top)
        }
    }

    /// That card's share of the damage — loss stats only, kept uncluttered.
    /// Real mode adds a small imported-card footer (last import date,
    /// confidence hint) below the stats.
    private func statsPanel(_ account: LinkedAccount) -> some View {
        let accountLoss = loss(account)
        let share = totalLoss > 0 ? Int((accountLoss / totalLoss * 100).rounded()) : 0
        let pct = markupPct(account)
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatCard(
                    label: "Taken from you",
                    value: Derive.fmtMoney(accountLoss),
                    countTo: accountLoss,
                    countPrefix: Derive.moneySymbol,
                    pill: "\(share)%",
                    pillTone: .bad,
                    sub: "of your \(Derive.fmtMoney(totalLoss)) total"
                )
                StatCard(
                    label: "Foreign charges",
                    value: "\(txCount(account))",
                    countTo: Double(txCount(account)),
                    pill: pct.map { "~" + Derive.fmtPct($0) },
                    pillTone: (pct ?? 0) <= 1.5 ? .good : .bad,
                    sub: "typical FX markup"
                )
            }

            if let imported = importedCard(for: account) {
                importedCardFooter(imported)
            }
        }
    }

    private func importedCardFooter(_ card: ImportedCard) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.lastImportAt.map { "Last imported \(Derive.fmtDate(Derive.isoDate($0)))" } ?? "Not yet imported")
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Theme.cream.opacity(0.85))
                if let hint = confidenceHint(card) {
                    Text(hint)
                        .font(.app(10))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
        }
        .padding(14)
        .surfaceCard(cornerRadius: 16)
    }

    // MARK: - Selection + tilt

    private func card(_ account: LinkedAccount, w: CGFloat, h: CGFloat, isFocused: Bool = false) -> some View {
        CardFace(account: account, markupPct: markupPct(account), isFocused: isFocused)
            .frame(width: w, height: h)
            // CardFace's background artwork (radial glow, arc circles) overflows
            // the card bounds; clipShape clips drawing but NOT hit-testing, so in
            // the fan a front card's invisible overflow swallowed taps aimed at
            // the exposed strip of the card behind it (the DBS bug). Confine
            // hit-testing to the visible card face.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func select(_ id: String) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { selectedId = id }
    }

    private func deselect() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { selectedId = nil }
        tilt = .zero
    }

    private var tiltX: Double { max(-5, min(5, Double(-tilt.height) / 16)) }
    private var tiltY: Double { max(-5, min(5, Double(tilt.width) / 16)) }

    /// Gyroscope parallax — the phone's tilt makes the focused card catch the
    /// light like a physical object. Composed on top of the drag tilt. Flat in
    /// the Simulator (no gyro) and under Reduce Motion. Pitch drives the x-axis
    /// rotation, roll the y-axis, mirroring the drag mapping above.
    private var gyroX: Double { reduceMotion ? 0 : max(-7, min(7, motion.pitch * 7)) }
    private var gyroY: Double { reduceMotion ? 0 : max(-7, min(7, motion.roll * 7)) }

    private var tiltGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in tilt = value.translation }
            .onEnded { _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { tilt = .zero }
            }
    }
}

// MARK: - Card face artwork

/// Full card-sized artwork grown out of BankMark: the bank's brand color
/// woven through a dark gradient, a hot corner glow (the tripModeCard
/// treatment), concentric arc flourishes, and an amber EMV chip. Distinct
/// per bank, cohesive with the app.
private struct CardFace: View {
    let account: LinkedAccount
    let markupPct: Double?
    var isFocused: Bool = false

    private var brand: Color { BankMark.brandColor(for: account.institutionName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BankMark(bank: account.institutionName, size: 30)
                Text(account.institutionName.uppercased())
                    .font(.app(11, weight: .bold))
                    .kerning(2.2)
                    .foregroundStyle(Theme.cream.opacity(0.85))
                Spacer()
                Image(systemName: "wave.3.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.cream.opacity(0.55))
            }

            Spacer()

            chip
                .padding(.bottom, 14)

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName)
                        .font(.app(18, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                    Text("····  \(account.last4)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .kerning(1.5)
                        .foregroundStyle(Theme.cream.opacity(0.6))
                }
                Spacer()
                if let markupPct {
                    Text("~\(Derive.fmtPct(markupPct)) FX")
                        .font(.app(9.5, weight: .bold))
                        .kerning(0.4)
                        .foregroundStyle(markupPct <= 1.5 ? Theme.good : Theme.loss)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            (markupPct <= 1.5 ? Theme.good : Theme.loss).opacity(0.14),
                            in: Capsule()
                        )
                }
            }
        }
        .padding(20)
        .background { artwork }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            brand.opacity(0.25),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .overlay {
            // Glint across the face when a card takes focus.
            if isFocused {
                LightSweep()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
        .shadow(color: brand.opacity(isFocused ? 0.22 : 0.1), radius: 20, x: 0, y: 12)
    }

    private var artwork: some View {
        ZStack(alignment: .topTrailing) {
            // Deep surface base with the brand color woven through.
            LinearGradient(
                colors: [brand.opacity(0.5), Theme.surface2, Theme.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Hot corner glow — same treatment as Home's trip-mode card.
            RadialGradient(
                colors: [brand.opacity(0.45), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 120
            )
            .frame(width: 240, height: 240)
            .blur(radius: 26)
            .offset(x: 80, y: -80)

            // Concentric arc flourish rising from the bottom-left.
            ZStack {
                Circle()
                    .strokeBorder(brand.opacity(0.14), lineWidth: 1.2)
                    .frame(width: 220, height: 220)
                    .offset(x: -80, y: 130)
                Circle()
                    .strokeBorder(brand.opacity(0.08), lineWidth: 1.2)
                    .frame(width: 310, height: 310)
                    .offset(x: -95, y: 150)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            // Top sheen so the surface reads as glass, not flat paint.
            LinearGradient(
                colors: [Color.white.opacity(0.07), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    /// Small amber EMV chip — the one skeuomorphic detail that sells
    /// "this is a card", kept in the app's own gold.
    private var chip: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.5), Theme.accent.opacity(0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 34, height: 25)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8)
            )
            .overlay(
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.black.opacity(0.25))
                            .frame(width: 1.5)
                    }
                }
                .padding(.vertical, 4)
            )
    }
}
