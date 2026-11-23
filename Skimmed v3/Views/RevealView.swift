import StoreKit
import SwiftUI
import UIKit

/// The Reveal — the paywall moment (ported from `app/reveal/page.tsx`).
/// Number first, everything else below the fold, blurred until unlocked.
/// The count-up is the emotional payoff: embers drift up behind the glass,
/// the glow breathes, and when the number settles a light sweep crosses the
/// card with a heavy haptic. Tapping the CTA plays the unlock — the pricing
/// sheet drops away, the view scrolls to the locked stats, and each lock
/// dissolves in cascade before routing to Home.
///
/// Data comes from `AppStore.shared`, derived from imported statements —
/// this screen is only reachable after a real analysis. Gating is real:
/// `EntitlementStore.shared.hasFullAccess` decides whether the number and
/// locked sections unlock.
struct RevealView: View {
    /// Called when the unlock sequence finishes OR the user chooses to
    /// continue with limited results (routes to Home either way — B6's
    /// views decide what "limited" looks like from `hasFullAccess` /
    /// `paywall.continuedLimited`).
    var onUnlock: () -> Void

    private let copy = Copy.active

    @ObservedObject private var appStore = AppStore.shared
    @ObservedObject private var entitlements = EntitlementStore.shared

    /// Set by the paywall's "Continue with limited results" — B6's Home /
    /// other surfaces read this to keep showing locked/limited stats even
    /// though onboarding has finished.
    @AppStorage("paywall.continuedLimited") private var continuedLimited = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var countDone = false
    @State private var showEyebrow = false
    @State private var showNumberCard = false
    @State private var showMethodology = false
    @State private var showLockedSections = false
    @State private var showSheet = false
    /// The celebratory "you're all set" card that pops up after the unlock
    /// cascade finishes, just before routing to Home.
    @State private var showAllSet = false
    @State private var glowPulse = false
    @State private var shine = false
    @State private var unlocked = false
    @State private var scrollY: CGFloat = 0

    // Real-paywall-only state
    @State private var selectedProductID: String? = nil
    @State private var purchaseErrorMessage: String? = nil
    @State private var restoreMessage: String? = nil
    @State private var restoring = false

    // Sheet geometry — measured, never magic numbers. The real paywall grew
    // to three product rows plus headline, sub-copy, CTA, error line and
    // bottom links; a hardcoded reserve/hide offset either clipped the sheet
    // at rest or left a sliver on the way out. We measure the live sheet
    // height and read the home-indicator inset, then derive both the scroll
    // reserve and the fully-off-screen hide distance from them.

    /// Live height of the resting pricing sheet (includes its own bottom
    /// padding), captured via `onGeometryChange` on whichever sheet is shown.
    @State private var sheetHeight: CGFloat = 0
    /// Device bottom safe-area inset (home indicator), read live so the sheet
    /// rests above it and clears it completely when it drops away.
    @State private var bottomSafeArea: CGFloat = 0

    // MARK: - Derived from AppStore

    private var snapshot: RevealSnapshot { appStore.revealSnapshot }

    private var worst: LinkedAccount? {
        appStore.linkedAccounts.first { $0.id == snapshot.worstOffenderLinkedAccountId }
    }

    private var worstLoss: Double {
        guard let worst else { return 0 }
        return Derive.markupForAccount(appStore.transactions, accountId: worst.id)
    }

    private var dccLoss: Double {
        Derive.totalMarkup(appStore.transactions.filter { $0.isDccSuspected })
    }

    private var recentTxs: [Transaction] {
        Array(appStore.transactions.sorted { $0.txDate > $1.txDate }.prefix(8))
    }

    /// The one un-blurred "free taste" row — the worst single markup among
    /// what's actually shown, so the taste is always visible, never hidden
    /// past the 8-row cutoff.
    private var freeTasteTxID: String? {
        recentTxs.max(by: { $0.markupAmount < $1.markupAmount })?.id
    }

    private var ranking: CardRanking? { appStore.cardRankings.first }

    private var overallRateEvidence: (text: String, provisional: Bool)? {
        let pricedForeign = appStore.calculationTransactions.filter {
            $0.isForeign && $0.confidence != .unableToCalculate && $0.markupAmount != nil
        }
        if pricedForeign.contains(where: { $0.resolvedCalculationStatus == .provisional }) {
            return ("Reference estimate · updates automatically", true)
        }
        if pricedForeign.contains(where: {
            $0.resolvedCalculationStatus == .verified && $0.referenceRateSource == .ecb
        }) {
            return ("ECB daily rates", false)
        }
        return nil
    }

    private var worstSharePct: Int {
        guard snapshot.totalLossAmount > 0 else { return 0 }
        return Int((worstLoss / snapshot.totalLossAmount * 100).rounded())
    }

    /// "We analysed N transactions · M foreign · K may include extra FX
    /// costs" — the real proof counts shown before the paywall (from the
    /// just-built snapshot / `AppStore.transactions`).
    private var proofN: Int { snapshot.transactionCount }
    private var proofM: Int { appStore.transactions.filter(\.isForeign).count }
    private var proofK: Int { appStore.transactions.filter { $0.markupAmount > 0 }.count }

    // MARK: - Sheet geometry (derived from the measured sheet)

    /// Bottom padding reserved under the scroll content so the last locked
    /// card can always scroll clear of the resting sheet. Falls back to the
    /// old constant until the first measurement lands.
    private var sheetReserve: CGFloat {
        (sheetHeight > 0 ? sheetHeight : 210) + 24
    }

    /// How far to push the sheet down so it sits fully below the screen edge:
    /// measured height + home-indicator inset + a small margin. Guaranteed to
    /// clear even the tall three-option real paywall, so no sliver lingers
    /// during the unlock cascade.
    private var sheetHiddenOffset: CGFloat {
        (sheetHeight > 0 ? sheetHeight : 320) + bottomSafeArea + 24
    }

    /// Bottom safe-area inset read straight off the active key window — the
    /// only place it survives, since the app's root ZStack insets RevealView
    /// before any nested GeometryReader could see it.
    private static var windowBottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        eyebrow
                            .padding(.top, 40)

                        numberCard
                            .padding(.top, 24)

                        methodologyRow
                            .padding(.top, 20)

                        lockedSections
                            .padding(.top, 40)
                            .id("lockedSections")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, sheetReserve) // measured room for the sticky pricing sheet
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { _, new in
                    scrollY = new
                }

                realPaywallSheet(proxy: proxy)

                // The finishing beat — pops up from the bottom after the
                // paywall has slid away and the report has revealed.
                if showAllSet {
                    allSetCard
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                        .zIndex(10)
                }
            }
            // Capture the home-indicator inset once the view is on screen.
            // A GeometryReader nested here reads 0 — the app's root ZStack has
            // already consumed the safe area before RevealView — so we read it
            // straight off the key window instead. Drives the fully-clear hide.
            .onAppear { bottomSafeArea = Self.windowBottomInset }
        }
        .task {
            // If the user already owns full access (e.g. a restored purchase
            // from a previous session), skip the gate entirely — no sheet,
            // no cascade, straight to unlocked.
            if entitlements.hasFullAccess {
                unlocked = true
            }
            if selectedProductID == nil {
                selectedProductID = EntitlementStore.plusAnnualID
            }
            // Staggered entrance, mirroring the prototype's motion delays.
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) { showEyebrow = true }
            withAnimation(.spring(duration: 0.7, bounce: 0.22).delay(0.35)) { showNumberCard = true }
            withAnimation(.easeOut(duration: 0.4).delay(1.4)) { showMethodology = true }
            withAnimation(.easeOut(duration: 0.5).delay(1.8)) { showLockedSections = true }
            if !unlocked {
                withAnimation(.spring(duration: 0.55).delay(2.6)) { showSheet = true }
            }
            if !reduceMotion {
                withAnimation(
                    .easeInOut(duration: 2.6).repeatForever(autoreverses: true).delay(1.0)
                ) { glowPulse = true }
            }
            // Already entitled (restored purchase, or a repeat import while
            // subscribed): there's no paywall sheet, so nothing would ever
            // call `onUnlock` — the reveal unlocks through on its own once
            // the count-up settles, instead of stranding the user here.
            if unlocked {
                try? await Task.sleep(nanoseconds: 4_200_000_000)
                guard !Task.isCancelled else { return }
                onUnlock()
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: countDone)
        .sensoryFeedback(.success, trigger: unlocked)
    }

    // MARK: - The number

    private var eyebrow: some View {
        Text("We analysed \(proofN) transactions · \(proofM) foreign · \(proofK) may include extra FX costs".uppercased())
            .font(.app(11, weight: .semibold))
            .kerning(1.6)
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            .opacity(showEyebrow ? 1 : 0)
    }

    private var numberCard: some View {
        VStack(spacing: 0) {
            Text("You lost")
                .font(.app(13, weight: .semibold))
                .foregroundStyle(Theme.cream.opacity(0.8))

            // The warm-gradient loss number, lit from within — always shown
            // in the clear: the total IS the hook. What's paywalled is the
            // breakdown below (per-charge amounts, worst offender, ranking),
            // never the headline damage. The glow shadow flares slightly
            // when the count settles.
            CountUpText(
                to: snapshot.totalLossAmount,
                duration: 2.6,
                delay: 0.7,
                prefix: Derive.moneySymbol,
                onDone: {
                    withAnimation(.easeOut(duration: 0.5)) { countDone = true }
                    shine = true
                }
            )
            .font(.app(64, weight: .heavy))
            .foregroundStyle(Theme.lossGradient)
            .shadow(
                color: Theme.accentHot.opacity(countDone ? 0.5 : 0.35),
                radius: countDone ? 30 : 24
            )
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.top, 4)

            Text(copy.revealHeadlineSuffix)
                .font(.app(15, weight: .semibold))
                .foregroundStyle(Theme.cream.opacity(0.9))
                .padding(.top, 12)

            Text(copy.revealSubline)
                .font(.app(13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 16)
                .opacity(countDone ? 1 : 0)
                .offset(y: countDone ? 0 : 8)

            if let evidence = overallRateEvidence {
                RateEvidenceBadge(text: evidence.text, provisional: evidence.provisional)
                    .padding(.top, 12)
                    .opacity(countDone ? 1 : 0)
                    .offset(y: countDone ? 0 : 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
        .glass()
        .overlay {
            // One-shot glint across the glass when the number settles.
            if shine {
                LightSweep()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .background {
            ZStack {
                // Embers drifting up behind the glass — depth without noise.
                if !reduceMotion {
                    EmberField()
                        .frame(width: 340, height: 400)
                        .offset(y: -12)
                }

                // Radial glow behind the glass card — lit from within,
                // breathing slowly and trailing the scroll for parallax.
                RadialGradient(
                    colors: [
                        Theme.accentHot.opacity(0.4),
                        Theme.loss.opacity(0.18),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 170
                )
                .frame(width: 300, height: 300)
                .scaleEffect(glowPulse ? 1.08 : 0.96)
                .opacity(glowPulse ? 1 : 0.82)
                .blur(radius: 40)
                .offset(y: scrollY * 0.22)
            }
            .allowsHitTesting(false)
        }
        .opacity(showNumberCard ? 1 : 0)
        .scaleEffect(showNumberCard ? 1 : 0.94)
        .offset(y: showNumberCard ? 0 : 16)
        .rotation3DEffect(
            .degrees(showNumberCard ? 0 : 7),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.6
        )
    }

    private var methodologyRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .padding(.top, 2)
            Text(copy.revealMethodology)
                .font(.app(10.5))
                .lineSpacing(3)
        }
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: 320)
        .opacity(showMethodology ? 1 : 0)
    }

    // MARK: - Locked content below the fold

    private var lockedSections: some View {
        VStack(spacing: 16) {
            // The tx card blurs its own amounts; the wrapper only adds the
            // in-place reveal polish (settle scale + amber sweep + glow) so
            // it moves in lockstep with the locked cards below. No chip, no
            // whole-card blur — it stays the visible "free taste".
            UnlockReveal(
                label: nil,
                blurContent: false,
                isLocked: !unlocked,
                delay: 0,
                reduceMotion: reduceMotion
            ) {
                transactionListCard
            }
            if let worst {
                worstOffenderCard(worst)
            }
            if snapshot.dccTrapCount > 0 {
                dccTrapsCard
            }
            if let ranking {
                cardRankingCard(ranking)
            }
        }
        .opacity(showLockedSections ? 1 : 0)
        .offset(y: showLockedSections ? 0 : 24)
    }

    /// Full transaction list — rows visible; loss amounts blurred until
    /// unlock, except the one worst-markup row shown as a free taste.
    private var transactionListCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot.transactionCount) charges analyzed")
                    .font(.app(13, weight: .bold))
                    .foregroundStyle(Theme.cream)
                Spacer()
                Text("LAST 12 MONTHS")
                    .font(.app(10))
                    .kerning(0.8)
                    .foregroundStyle(Theme.muted)
            }

            VStack(spacing: 14) {
                ForEach(recentTxs) { tx in
                    TxRow(tx: tx, blurAmount: !unlocked && tx.id != freeTasteTxID)
                }
            }
            .padding(.top, 16)

            if snapshot.transactionCount > recentTxs.count {
                Text("+ \(snapshot.transactionCount - recentTxs.count) more charges")
                    .font(.app(11))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
        }
        .padding(20)
        .surfaceCard()
    }

    private func worstOffenderCard(_ worst: LinkedAccount) -> some View {
        UnlockReveal(label: "Unlock to see your worst offender", blurContent: true, isLocked: !unlocked, delay: 0.14, reduceMotion: reduceMotion) {
            VStack(alignment: .leading, spacing: 0) {
                sectionEyebrow(icon: "flame.fill", tint: Theme.loss, text: "Your worst offender")

                HStack(spacing: 10) {
                    BankMark(bank: worst.institutionName, size: 30)
                    Text("\(worst.displayName) ···· \(worst.last4)")
                        .font(.app(17, weight: .bold))
                        .foregroundStyle(Theme.cream)
                }
                .padding(.top, 8)

                Text("took \(Text(Derive.fmtMoney(worstLoss)).bold().foregroundStyle(Theme.loss)) of your \(Derive.fmtMoney(snapshot.totalLossAmount)) — \(worstSharePct)% of the damage")
                    .font(.app(13))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .surfaceCard()
        }
    }

    private var dccTrapsCard: some View {
        UnlockReveal(label: "Unlock your DCC traps", blurContent: true, isLocked: !unlocked, delay: 0.28, reduceMotion: reduceMotion) {
            VStack(alignment: .leading, spacing: 0) {
                sectionEyebrow(icon: "exclamationmark.shield.fill", tint: Theme.accent, text: "DCC traps caught")

                Text("\(snapshot.dccTrapCount) × \"pay in \(Derive.homeCurrencyCode)?\" at the terminal")
                    .font(.app(17, weight: .bold))
                    .foregroundStyle(Theme.cream)
                    .padding(.top, 8)

                Text("cost you \(Text(Derive.fmtMoney(dccLoss)).bold().foregroundStyle(Theme.loss)) on top of the markups")
                    .font(.app(13))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .surfaceCard()
        }
    }

    private func cardRankingCard(_ ranking: CardRanking) -> some View {
        UnlockReveal(label: "Unlock your card ranking", blurContent: true, isLocked: !unlocked, delay: 0.42, reduceMotion: reduceMotion) {
            VStack(alignment: .leading, spacing: 0) {
                sectionEyebrow(
                    icon: "sparkles",
                    tint: Theme.accent,
                    text: rankingHeading(ranking)
                )

                VStack(spacing: 10) {
                    ForEach(Array(ranking.rankedAccounts.enumerated()), id: \.offset) { index, ranked in
                        if let account = appStore.linkedAccounts.first(where: { $0.id == ranked.linkedAccountId }) {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.app(12, weight: .bold))
                                    .foregroundStyle(Theme.muted)
                                    .frame(width: 16, alignment: .leading)
                                BankMark(bank: account.institutionName, size: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.displayName)
                                        .font(.app(13, weight: .semibold))
                                        .foregroundStyle(Theme.cream)
                                    RateEvidenceBadge(
                                        text: rankingBadge(ranking, confidence: ranked.confidence),
                                        provisional: ranking.evidenceTier != .verifiedDestination
                                    )
                                }
                                Spacer()
                                Text((ranking.evidenceTier == .verifiedDestination ? "" : "~") + Derive.fmtPct(ranked.markupPct))
                                    .font(.app(12, weight: .bold))
                                    .foregroundStyle(Theme.cream.opacity(0.8))
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .surfaceCard()
        }
    }

    private func rankingHeading(_ ranking: CardRanking) -> String {
        switch ranking.evidenceTier {
        case .verifiedDestination:
            return "Best observed for \(ranking.destinationCurrency)"
        case .verifiedCrossCurrency:
            return "Limited guide for \(ranking.destinationCurrency)"
        case .provisionalDestination:
            return "Provisional guide for \(ranking.destinationCurrency)"
        }
    }

    private func rankingBadge(
        _ ranking: CardRanking,
        confidence: RecommendationConfidence
    ) -> String {
        switch ranking.evidenceTier {
        case .verifiedDestination:
            return confidence.evidenceLabel
        case .verifiedCrossCurrency:
            return "Cross-currency evidence"
        case .provisionalDestination:
            return "Offline estimate · updates"
        }
    }

    private func sectionEyebrow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text.uppercased())
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: - Sticky pricing sheet (the paywall)

    private func realPaywallSheet(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your full Skimmed report is ready.")
                .font(.app(16, weight: .bold))
                .foregroundStyle(Theme.cream)

            Text("Every priced foreign charge, your worst offender, and your card ranking — unlocked for good, or kept current all year.")
                .font(.app(11.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
                .padding(.top, 6)

            if entitlements.loadError && entitlements.products.isEmpty {
                unavailableState(proxy: proxy)
            } else if entitlements.products.isEmpty {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            } else {
                productOptions
                    .padding(.top, 14)

                PrimaryButton(
                    title: entitlements.purchaseInFlight ? "Processing…" : "Unlock my full report",
                    trailingIcon: nil,
                    isDisabled: entitlements.purchaseInFlight || selectedProductID == nil
                ) {
                    purchaseSelected(proxy: proxy)
                }
                .padding(.top, 16)

                if let purchaseErrorMessage {
                    Text(purchaseErrorMessage)
                        .font(.app(11))
                        .foregroundStyle(Theme.loss)
                        .padding(.top, 8)
                }

                bottomLinks(proxy: proxy)
                    .padding(.top, 12)
            }
        }
        .padding(20)
        .glass()
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
        .offset(y: showSheet ? 0 : sheetHiddenOffset)
    }

    /// Honest degradation — no config attached, no network, or products not
    /// yet propagated. Describes the plans without inventing prices, and
    /// always offers Restore.
    private func unavailableState(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Purchases can't load right now — check your connection and try again in a moment.")
                .font(.app(12, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("· Full Report — one-time, this report is yours for good")
                Text("· Skimmed Plus — yearly, unlimited imports and updates")
                Text("· Skimmed Plus — monthly, cancel anytime")
            }
            .font(.app(11))
            .foregroundStyle(Theme.muted)
            .lineSpacing(2)

            bottomLinks(proxy: proxy)
        }
    }

    private var productOptions: some View {
        VStack(spacing: 10) {
            if let full = entitlements.fullReportProduct {
                productOptionRow(product: full, subtitle: "One-time — yours for good")
            }
            if let plus = entitlements.plusAnnualProduct {
                productOptionRow(product: plus, subtitle: trialLine(for: plus))
            }
            if let monthly = entitlements.plusMonthlyProduct {
                productOptionRow(product: monthly, subtitle: "\(monthly.displayPrice)/month — cancel anytime")
            }
        }
    }

    private func trialLine(for product: Product) -> String {
        if let intro = product.subscription?.introductoryOffer, intro.paymentMode == .freeTrial {
            return "\(periodDescription(intro.period)) free trial, then \(product.displayPrice)/year"
        }
        return "\(product.displayPrice)/year"
    }

    private func periodDescription(_ period: Product.SubscriptionPeriod) -> String {
        let unitName: String
        switch period.unit {
        case .day: unitName = "day"
        case .week: unitName = "week"
        case .month: unitName = "month"
        case .year: unitName = "year"
        @unknown default: unitName = "period"
        }
        let plural = period.value == 1 ? unitName : "\(unitName)s"
        return "\(period.value)-\(plural)"
    }

    private func productOptionRow(product: Product, subtitle: String) -> some View {
        let isSelected = selectedProductID == product.id
        return Button {
            selectedProductID = product.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.muted.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.app(13, weight: .bold))
                        .foregroundStyle(Theme.cream)
                    Text(subtitle)
                        .font(.app(11))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.app(13, weight: .bold))
                    .foregroundStyle(Theme.cream)
            }
            .padding(14)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Color.white.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    private func bottomLinks(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            Button {
                continueWithLimited()
            } label: {
                Text("Continue with limited results")
                    .font(.app(12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(PressStyle(scale: 0.97))

            Button {
                handleRestore(proxy: proxy)
            } label: {
                Text(restoring ? "Restoring…" : "Restore purchases")
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .disabled(restoring)

            if let restoreMessage {
                Text(restoreMessage)
                    .font(.app(10.5))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func purchaseSelected(proxy: ScrollViewProxy) {
        guard let id = selectedProductID,
              let product = entitlements.products.first(where: { $0.id == id }) else { return }
        purchaseErrorMessage = nil
        Task {
            do {
                try await entitlements.purchase(product)
                if entitlements.hasFullAccess {
                    runUnlockCascade(proxy: proxy)
                }
            } catch {
                purchaseErrorMessage = "Something went wrong — please try again."
            }
        }
    }

    private func handleRestore(proxy: ScrollViewProxy) {
        Task {
            restoring = true
            await entitlements.restore()
            restoring = false
            if entitlements.hasFullAccess {
                restoreMessage = "Restored — your full report is unlocked."
                runUnlockCascade(proxy: proxy)
            } else {
                restoreMessage = "No previous purchase found."
            }
        }
    }

    /// "Continue with limited results" — routes onward WITHOUT unlocking
    /// content. `paywall.continuedLimited` lets B6's Home/other surfaces
    /// keep showing locked/limited stats even past onboarding.
    private func continueWithLimited() {
        continuedLimited = true
        withAnimation(.spring(duration: 0.6, bounce: 0)) { showSheet = false }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            onUnlock()
        }
    }

    /// The payoff, staged so nothing ever obscures anything else:
    ///   1. the pricing sheet glides fully off the bottom FIRST (it's the only
    ///      thing covering content, so it leaves before the reveal begins),
    ///   2. once it's clear, the locked sections dissolve in place, staggered
    ///      (no `scrollTo` re-anchor — that used to yank the text column up),
    ///   3. after the cascade settles, a "you're all set" card pops up from the
    ///      bottom as the finishing beat, then we route to Home.
    /// Runs after a successful purchase/restore.
    private func runUnlockCascade(proxy _: ScrollViewProxy) {
        guard !unlocked else { return }
        withAnimation(.spring(duration: 0.6, bounce: 0)) { showSheet = false }
        Task {
            // 1 → 2: let the sheet clear the screen before the reveal starts.
            try? await Task.sleep(nanoseconds: 620_000_000)
            unlocked = true
            // 2 → 3: hold while the staggered cascade finishes revealing.
            try? await Task.sleep(nanoseconds: 1_650_000_000)
            withAnimation(
                reduceMotion
                    ? .easeOut(duration: 0.35)
                    : .spring(response: 0.5, dampingFraction: 0.66)
            ) { showAllSet = true }
            // Hold the celebratory beat, then route to Home.
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            onUnlock()
        }
    }

    /// "You're all set" — a compact glass card that springs up from the bottom
    /// after the report is revealed, in the same quiet-luxury language as the
    /// pricing sheet it replaces.
    private var allSetCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.18))
                    .frame(width: 48, height: 48)
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }

            Text("You're all set.")
                .font(.app(17, weight: .heavy))
                .foregroundStyle(Theme.cream)

            Text("Your full report is unlocked.")
                .font(.app(12))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
        .glass()
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .sensoryFeedback(.success, trigger: showAllSet)
    }
}

// MARK: - Ember particle field

/// Sparse warm embers drifting upward on a Canvas — pure decoration behind
/// the Reveal number. Deterministic per-index pseudo-randomness (no
/// Math.random-style state), ~30fps, skipped entirely under Reduce Motion.
private struct EmberField: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for i in 0..<16 {
                    let seed = Double(i)
                    let speed = 12 + seed.truncatingRemainder(dividingBy: 5) * 4
                    let travel = (t * speed + seed * 97)
                        .truncatingRemainder(dividingBy: Double(size.height) + 40)
                    let y = Double(size.height) + 20 - travel
                    let sway = sin(t * (0.5 + seed.truncatingRemainder(dividingBy: 3) * 0.25) + seed) * 14
                    let x = (seed * 53.7).truncatingRemainder(dividingBy: Double(size.width)) + sway
                    let radius = 1.0 + (seed * 3.3).truncatingRemainder(dividingBy: 2.2)
                    // Fade in near the bottom edge, fade out toward the top.
                    let fade = min(1, travel / 90) * min(1, (Double(size.height) + 40 - travel) / 140)
                    let rect = CGRect(x: x, y: y, width: radius, height: radius)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(Theme.accentHot.opacity(0.45 * fade))
                    )
                }
            }
        }
        .blur(radius: 0.6)
        .allowsHitTesting(false)
    }
}

// MARK: - In-place unlock reveal

/// Reveals its content WITHOUT ever changing layout: the card keeps its
/// natural, identical height whether locked or unlocked, so nothing reflows
/// and no text is ever pushed out of its box. The lock dissolves in place —
/// blur→clear, a subtle settle-scale from 0.98 (non-layout `scaleEffect`), a
/// soft amber light-sweep, and a one-shot amber glow pulse around the edge,
/// staggered by `delay` so siblings cascade. The lock chip fades (opacity
/// only — never a move/scale that could jump).
///
/// `blurContent: false` is for the transaction card, which blurs its own
/// amounts and carries no chip: it still gets the settle-scale + sweep + glow
/// so it moves in lockstep with the cards below.
///
/// Reduce Motion: pure cross-dissolve — no scale, no sweep, no glow.
private struct UnlockReveal<Content: View>: View {
    var label: String?
    var blurContent: Bool
    var isLocked: Bool
    var delay: Double
    var reduceMotion: Bool
    @ViewBuilder var content: () -> Content

    @State private var sweeping = false
    @State private var glowing = false

    var body: some View {
        content()
            .blur(radius: blurContent && isLocked ? 7 : 0)
            .opacity(blurContent && isLocked ? 0.55 : 1)
            .scaleEffect(!reduceMotion && isLocked ? 0.98 : 1)
            .allowsHitTesting(!isLocked)
            .accessibilityHidden(blurContent && isLocked)
            // NOTE: the content is intentionally NOT clipped here — the wrapped
            // surfaceCard casts a soft drop shadow beyond its bounds, and
            // clipping would crop it. The sweep overlay clips itself instead.
            .overlay {
                // Amber glow pulse — always present, invisible until it fires,
                // so it never affects layout.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(glowing ? 0.55 : 0), lineWidth: 1.5)
                    .blur(radius: 6)
                    .allowsHitTesting(false)
            }
            .overlay {
                if sweeping {
                    AmberSweep()
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if let label, isLocked {
                    lockChip(label)
                        .transition(.opacity)
                }
            }
            .animation(revealAnimation.delay(delay), value: isLocked)
            .onChange(of: isLocked) { _, locked in
                guard !locked, !reduceMotion else { return }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64((delay + 0.12) * 1_000_000_000))
                    withAnimation(.easeInOut(duration: 0.5)) { glowing = true }
                    sweeping = true
                    try? await Task.sleep(nanoseconds: 850_000_000)
                    sweeping = false
                    withAnimation(.easeOut(duration: 0.6)) { glowing = false }
                }
            }
            // No per-card haptic — 4 cards flipping at once would stack into a
            // muddy buzz. The parent Reveal fires a single .success on unlock.
    }

    private var revealAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.5)
            : .spring(duration: 0.7, bounce: 0.16)
    }

    private func lockChip(_ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.app(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(.app(12, weight: .semibold))
                .foregroundStyle(Theme.cream.opacity(0.9))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: Capsule())
    }
}

/// One-shot warm shimmer band that sweeps across its bounds — the amber
/// cousin of `LightSweep`, used to lick across each section as its lock
/// dissolves. Runs once per appearance; callers clip it to their card shape.
private struct AmberSweep: View {
    @State private var progress: CGFloat = -0.6

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    .clear,
                    Theme.accent.opacity(0.28),
                    Theme.accentHot.opacity(0.14),
                    .clear,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.6)
            .rotationEffect(.degrees(16))
            .offset(x: progress * geo.size.width * 1.9)
            .blendMode(.plusLighter)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85)) { progress = 1.1 }
            }
        }
        .allowsHitTesting(false)
    }
}
