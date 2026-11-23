import StoreKit
import SwiftUI
import UIKit

/// Post-subscribe Home — the Recurring Discovery + Frictionless Action loop
/// (ported from `app/home/page.tsx`): trip mode, monthly damage report,
/// card ranking, DCC refusal script, latest finds. Reads `AppStore` (derived
/// from imported statements); with nothing imported it renders an
/// empty-state hero with the import CTA instead of the dashboard.
struct HomeView: View {

    @ObservedObject private var appStore = AppStore.shared
    @ObservedObject private var entitlements = EntitlementStore.shared
    @AppStorage("paywall.continuedLimited") private var continuedLimited = false
    @AppStorage("profile.name") private var storedName: String = ""
    @AppStorage("profile.tripFreq") private var storedTripFreq: String = ""
    @AppStorage("profile.destinations") private var storedDestinations: String = ""
    @AppStorage("profile.homeCurrency") private var storedHomeCurrency: String = RateProvider.defaultHomeCurrency

    @State private var copied = false
    @State private var appeared = false
    @State private var pulse = false
    @State private var barsAppeared = false

    /// Owned by MainTabs so the calm-night wash covers the whole page.
    @Binding var tripLive: Bool
    /// Routes to the Trips tab (MainTabs owns the selection) — the "View all
    /// trips" action, never a duplicate history sheet.
    var onViewAllTrips: () -> Void = {}
    /// Routes to the Trips tab and opens the trip matching a country (the
    /// leak map's tap-through).
    var onOpenTripCountry: (String) -> Void = { _ in }

    @State private var showSearch = false
    @State private var selectedTx: Transaction? = nil
    @State private var showSettings = false
    @State private var showUnlockSheet = false
    @State private var showWhichCard = false
    @State private var showEmptyStateImport = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Derived from AppStore

    private var monthly: [Derive.MonthLoss] { Derive.lossByMonth(appStore.transactions) }
    private var thisMonth: Derive.MonthLoss { monthly.last ?? Derive.MonthLoss(month: "", total: 0) }
    private var monthlyAvg: Double {
        guard !monthly.isEmpty else { return 0 }
        return monthly.reduce(0) { $0 + $1.total } / Double(monthly.count)
    }
    private var vsAvgPct: Int {
        guard monthlyAvg != 0 else { return 0 }
        return Int(((thisMonth.total / monthlyAvg - 1) * 100).rounded())
    }
    private var maxMonth: Double { monthly.map(\.total).max() ?? 1 }

    private func tripTxs(_ trip: Trip) -> [Transaction] {
        // Window-based, matching TripBuilderCore's totals — a stopover on
        // the way home belongs to the trip.
        appStore.transactions.filter {
            $0.isForeign
                && $0.txDate >= trip.startDate
                && (trip.endDate == nil || $0.txDate <= trip.endDate!)
        }
    }
    private func tripDcc(_ trip: Trip) -> Transaction? { tripTxs(trip).first { $0.isDccSuspected } }
    private func tripDay(_ trip: Trip) -> Int {
        max(1, Derive.daysBetween(trip.startDate, Derive.isoToday) + 1)
    }
    private var monthDcc: [Transaction] {
        appStore.transactions.filter {
            $0.isDccSuspected && $0.txDate.hasPrefix(thisMonth.month)
        }
    }
    private var recentFinds: [Transaction] {
        Array(appStore.transactions.sorted { $0.txDate > $1.txDate }.prefix(4))
    }
    private var totalLoss: Double { appStore.revealSnapshot.totalLossAmount }

    /// Observed markup lost per merchant country — the leak map's data.
    /// Unknown-geography rows ("??") are skipped, never guessed.
    private var lossByCountry: [String: Double] {
        var sums: [String: Double] = [:]
        for tx in appStore.transactions where tx.isForeign && tx.markupAmount > 0 {
            guard let country = tx.displayCountry else { continue }
            sums[country, default: 0] += tx.markupAmount
        }
        return sums
    }
    private var dccTrapCount: Int { appStore.revealSnapshot.dccTrapCount }

    /// Past the paywall, having chosen "continue with limited results" —
    /// loss amounts stay blurred everywhere on Home until a purchase/restore
    /// succeeds.
    private var blurLoss: Bool {
        !entitlements.hasFullAccess && continuedLimited
    }

    private var tripFreq: TripFreqBucket? { TripFreqBucket(rawValue: storedTripFreq) }
    private var destinations: [String] {
        storedDestinations.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// No live trip, an import exists, and it's gone stale — the "statement
    /// getting stale" refresh nudge for frequent travelers.
    private var staleImportDate: Date? {
        guard appStore.liveTrip == nil else { return nil }
        guard let last = appStore.cards.compactMap(\.lastImportAt).max() else { return nil }
        guard Date().timeIntervalSince(last) > 30 * 86_400 else { return nil }
        return last
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                // Warm aurora — luminous amber light drifting behind the page,
                // filling the empty "No trip" state the user cited. Only mounted
                // when trip mode is off, so the animated full-screen Canvas never
                // burns frames while a live trip owns the hero.
                if !tripLive {
                    AuroraBackground()
                        .opacity(0.9)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                dashboardTop(proxy: proxy)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if appStore.hasNoData {
                            emptyStateHero
                        } else {
                            if blurLoss {
                                unlockBanner
                            }

                            if tripLive, let live = appStore.liveTrip {
                                tripModeCard(live, proxy: proxy)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                        removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                                    ))
                            } else if tripLive {
                                heroFramingCard
                            }

                            viewAllTripsLink

                            sectionHeader("\(Derive.monthLabel(thisMonth.month)) damage report")
                                .id("damageReport")
                                .padding(.top, 8)
                            if !lossByCountry.isEmpty {
                                LeakMapCard(
                                    lossByCountry: lossByCountry,
                                    blurAmounts: blurLoss,
                                    onOpenCountry: onOpenTripCountry
                                )
                            }
                            damageStats
                            lossTrendCard

                            sectionHeader("One-tap fixes")
                                .padding(.top, 8)
                            advisorSection
                                .id("dccScript")

                            sectionHeader("Latest finds")
                                .padding(.top, 8)
                            latestFindsCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 140) // room for the floating nav
                }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 28)
                        Color.black
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45).delay(0.05)) { appeared = true }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .fullScreenCover(isPresented: $showSearch) {
                SearchOverlay()
            }
            .fullScreenCover(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $selectedTx) { tx in
                TxDetailSheet(tx: tx)
            }
            .sheet(isPresented: $showWhichCard) {
                WhichCardSheet()
            }
            .sheet(isPresented: $showUnlockSheet) {
                UnlockReportSheet()
            }
            }
        }
    }

    // MARK: - Dashboard top

    private func dashboardTop(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                AvatarView(size: 42)
                    .opacity(tripLive ? 1 : 0.55)

                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting)
                        .font(.app(14, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                        .lineLimit(1)
                    Text("\(storedHomeCurrency) travel wallet")
                        .font(.app(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                HStack(spacing: 10) {
                    Text(planBadge)
                        .font(.app(9.5, weight: .bold))
                        .foregroundStyle(tripLive ? Theme.accent : Theme.muted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background((tripLive ? Theme.accent : Theme.muted).opacity(0.15), in: Capsule())
                        .fixedSize()

                    Button { showWhichCard = true } label: {
                        dashboardIcon("creditcard")
                    }
                    .buttonStyle(PressStyle(scale: 0.9))

                    Button { showSearch = true } label: {
                        dashboardIcon("magnifyingglass")
                    }
                    .buttonStyle(PressStyle(scale: 0.9))

                    Button { showSettings = true } label: {
                        dashboardIcon("gearshape")
                    }
                    .buttonStyle(PressStyle(scale: 0.9))
                }
            }

            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FX Fees")
                        .font(.app(27, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                    Text("Overview")
                        .font(.app(27, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        tripLive.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tripLive ? "airplane" : "moon.zzz.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(tripLive ? "Latest trip" : "No trip")
                            .font(.app(12, weight: .bold))
                    }
                    .foregroundStyle(tripLive ? Theme.onAccent : Theme.muted)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background {
                        if tripLive {
                            Capsule().fill(Theme.buttonGradient)
                        } else {
                            Capsule().fill(Color.white.opacity(0.06))
                        }
                    }
                    .overlay(
                        Capsule().strokeBorder(
                            tripLive ? Color.clear : Color.white.opacity(0.1),
                            lineWidth: 1
                        )
                    )
                    .shadow(
                        color: Theme.accent.opacity(tripLive ? 0.3 : 0),
                        radius: 12, y: 8
                    )
                }
                .buttonStyle(PressStyle(scale: 0.94))
                .sensoryFeedback(.impact(flexibility: .soft), trigger: tripLive)
                }
            }

            // No metric cards until there's something real to report — the
            // empty-state hero below owns the no-data moment.
            if !appStore.hasNoData {
            HStack(spacing: 12) {
                Locked(label: "Unlock to view", isLocked: blurLoss) {
                    OverviewMetricCard(
                        label: "Hidden markup",
                        value: Derive.fmtMoney(totalLoss),
                        badge: "\(appStore.revealSnapshot.transactionCount) tx found",
                        icon: "flame.fill",
                        tint: tripLive ? Theme.accent : Theme.muted,
                        onOpen: {
                            withAnimation(.easeInOut(duration: 0.45)) {
                                proxy.scrollTo("damageReport", anchor: .top)
                            }
                        }
                    )
                }

                if dccTrapCount > 0 {
                    OverviewMetricCard(
                        label: "DCC traps",
                        value: "\(dccTrapCount)",
                        badge: "decline \(Derive.homeCurrencyCode)",
                        icon: "shield.fill",
                        tint: Theme.good,
                        onOpen: {
                            withAnimation(.easeInOut(duration: 0.45)) {
                                proxy.scrollTo("dccScript", anchor: .top)
                            }
                        }
                    )
                }
            }
            }
        }
    }

    private func dashboardIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.cream)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.06), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            // 44pt hit target around the 34pt visual circle.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.app(13, weight: .bold))
            .kerning(1.4)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Unlock banner (real mode, continued-limited)

    private var unlockBanner: some View {
        Button { showUnlockSheet = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're viewing a limited report")
                        .font(.app(12.5, weight: .bold))
                        .foregroundStyle(Theme.cream)
                    Text("Unlock full report")
                        .font(.app(11))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(14)
            .glass(cornerRadius: 16)
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }

    // MARK: - View all trips (routes to the Trips tab)

    private var viewAllTripsLink: some View {
        Button(action: onViewAllTrips) {
            HStack(spacing: 10) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("View all trips")
                    .font(.app(12.5, weight: .bold))
                    .foregroundStyle(Theme.cream)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glass(cornerRadius: 16)
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }

    // MARK: - Greeting + plan badge

    /// Time-of-day greeting, personalized when onboarding captured a name.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String
        switch hour {
        case 5..<12: salutation = "Good morning"
        case 12..<18: salutation = "Good afternoon"
        default: salutation = "Good evening"
        }
        let name = storedName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? salutation : "\(salutation), \(name)"
    }

    /// Real plan state from StoreKit entitlements — never a fabricated tier.
    private var planBadge: String {
        if entitlements.isPlus { return "PLUS" }
        if entitlements.hasFullAccess { return "FULL REPORT" }
        return "FREE"
    }

    // MARK: - Empty state (nothing imported yet)

    /// Nothing imported (fresh skip-through, or after erasing all data) —
    /// the dashboard is replaced by one honest card with the import CTA.
    private var emptyStateHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accent)

            Text("See where your money leaks")
                .font(.app(22, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .padding(.top, 14)

            Text("Import a bank statement and Skimmed checks foreign charges with enough detail against a date-matched reference rate. Offline estimates are labelled and update automatically. Analysed on this device; your statement file is never stored.")
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
        .padding(.top, 8)
        .fullScreenCover(isPresented: $showEmptyStateImport) {
            ImportEntrySheet { showEmptyStateImport = false }
        }
    }

    // MARK: - Hero framing (no live trip — onboarding answers)

    /// Occasional travelers (1–2 trips, or no answer) get a forward-looking
    /// prep card; frequent travelers (10+/airports) get a monitoring line plus
    /// a stale-statement nudge once 30+ days have passed since the last import.
    /// Mid buckets (3–4 trips) are neutral — no card.
    @ViewBuilder
    private var heroFramingCard: some View {
        switch tripFreq {
        case .none:
            prepCard
        case .some(let freq) where freq.isOccasional:
            prepCard
        case .some(let freq) where freq.isFrequent:
            monitoringCard
        case .some:
            EmptyView()
        }
    }

    private var prepCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREPARE FOR YOUR NEXT TRIP")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)

            if !destinations.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(destinations, id: \.self) { dest in
                        Text("\(Derive.flag(dest)) \(CountryCatalog.name(for: dest))")
                            .font(.app(12, weight: .semibold))
                            .foregroundStyle(Theme.cream)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }
                }
            }

            Text("Import a statement after you return and we'll show you exactly what it cost.")
                .font(.app(12))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .surfaceCard(cornerRadius: 18)
    }

    private var monitoringCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text("MONITORING YOUR CARDS")
                    .font(.app(10, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.muted)
            }

            Text("We'll flag rip-off charges the moment a new statement comes in.")
                .font(.app(12))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)

            if let staleImportDate {
                Text("Your last import was \(Derive.fmtDate(Derive.isoDate(staleImportDate))) — statement getting stale. Import a fresh one to keep this accurate.")
                    .font(.app(11.5, weight: .semibold))
                    .foregroundStyle(Theme.accentHot)
                    .lineSpacing(3)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .surfaceCard(cornerRadius: 18)
    }

    // MARK: - Trip mode (live)

    private func tripModeCard(_ live: Trip, proxy: ScrollViewProxy) -> some View {
        let txs = tripTxs(live)
        let dcc = tripDcc(live)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .opacity(pulse ? 0.25 : 1)
                    Text("LATEST TRIP")
                        .font(.app(10, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.accent.opacity(0.15), in: Capsule())

                Spacer()

                Text("Day \(tripDay(live))")
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }

            Text("\(live.destinationCurrency) spending 💱")
                .font(.app(26, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .padding(.top, 12)

            Text("From your statements · \(txs.count) charges this trip")
                .font(.app(11.5))
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LOST THIS TRIP")
                        .font(.app(9.5, weight: .semibold))
                        .kerning(1.3)
                        .foregroundStyle(Theme.muted)
                    Text(Derive.fmtMoney(live.totalMarkupThisTrip))
                        .font(.app(20, weight: .bold))
                        .foregroundStyle(Theme.loss)
                        .blur(radius: blurLoss ? 6 : 0)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("DCC TRAPS")
                        .font(.app(9.5, weight: .semibold))
                        .kerning(1.3)
                        .foregroundStyle(Theme.muted)
                    Text("\(dcc == nil ? 0 : 1)")
                        .font(.app(20, weight: .bold))
                        .foregroundStyle(Theme.cream)
                }
            }
            .padding(.top, 16)

            if let dcc {
                dccAlert(dcc, proxy: proxy)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            ZStack(alignment: .topTrailing) {
                Theme.surface
                // Warm radial glow bleeding in from the top-right corner.
                RadialGradient(
                    colors: [Theme.accentHot.opacity(0.22), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 96
                )
                .frame(width: 192, height: 192)
                .blur(radius: 30)
                .offset(x: 64, y: -64)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 8)
    }

    private func dccAlert(_ tx: Transaction, proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.loss)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(Text(tx.merchantName).fontWeight(.bold)) billed you in \(Derive.homeCurrencyCode) — that DCC trap cost ~\(Text(Derive.fmtMoney(tx.markupAmount)).fontWeight(.bold).foregroundStyle(Theme.loss))")
                    .font(.app(12))
                    .foregroundStyle(Theme.cream.opacity(0.9))
                    .lineSpacing(2)

                HStack(spacing: 8) {
                    EstimatedBadge()
                    Button {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo("dccScript", anchor: .top)
                        }
                    } label: {
                        Text("Refusal script ↓")
                            .font(.app(12, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.loss.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Monthly damage report

    private var damageStats: some View {
        HStack(spacing: 12) {
            Locked(label: "Unlock", isLocked: blurLoss) {
                StatCard(
                    label: "Lost in \(Derive.monthLabel(thisMonth.month))",
                    value: Derive.fmtMoney(thisMonth.total),
                    countTo: thisMonth.total,
                    countPrefix: Derive.moneySymbol,
                    pill: (vsAvgPct >= 0 ? "+" : "") + "\(vsAvgPct)%",
                    pillTone: vsAvgPct >= 0 ? .bad : .good,
                    sub: "vs your monthly average"
                )
            }
            StatCard(
                label: "DCC traps caught",
                value: "\(monthDcc.count)",
                countTo: Double(monthDcc.count),
                pill: "−" + Derive.fmtMoney(Derive.totalMarkup(monthDcc)),
                pillTone: .bad,
                sub: "refuse 'pay in \(Derive.homeCurrencyCode)?'"
            )
        }
    }

    /// Loss trend — a soft amber area/line of markup lost per month. One
    /// refined chart in place of the old bar-grid + heat-square pair (which
    /// showed the same data twice). Reveals left-to-right on scroll-in.
    private var lossTrendCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("LOSS TREND")
                    .font(.app(10, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text("LAST \(monthly.count) MONTH\(monthly.count == 1 ? "" : "S")")
                    .font(.app(9))
                    .kerning(0.8)
                    .foregroundStyle(Theme.muted.opacity(0.7))
            }

            LossTrendChart(
                points: monthly.map(\.total),
                labels: monthly.map { Derive.monthLabel($0.month) },
                maxValue: maxMonth,
                accent: tripLive ? Theme.accent : Theme.muted,
                revealed: barsAppeared,
                reduceMotion: reduceMotion
            )
            .frame(height: 104)
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .surfaceCard()
        .onScrollVisibilityChange(threshold: 0.35) { visible in
            // The trend draws itself in when the chart scrolls into view.
            if visible && !barsAppeared { barsAppeared = true }
        }
    }

    // MARK: - Smart Advisor (the solve: right card, right words, this trip)

    /// The destination the advisor speaks to: the latest trip first, then the
    /// user's chosen destinations, then any currency we can rank at all.
    private var advisorCurrency: String? {
        if let live = appStore.liveTrip { return live.destinationCurrency }
        for dest in destinations {
            if let info = Derive.destinationInfo(dest),
               appStore.cardRankings.contains(where: { $0.destinationCurrency == info.currency }) {
                return info.currency
            }
        }
        return appStore.cardRankings.first?.destinationCurrency
            ?? destinations.compactMap { Derive.destinationInfo($0)?.currency }.first
    }

    /// What the pct gap between best and worst card would have kept on the
    /// latest trip — only quotable when the trip is in the advised currency.
    private func advisorTripSavings(_ ranking: CardRanking) -> Double? {
        guard let live = appStore.liveTrip,
              live.destinationCurrency == ranking.destinationCurrency,
              ranking.evidenceTier == .verifiedDestination,
              ranking.rankedAccounts.filter(\.isTiedBest).count == 1,
              let best = ranking.rankedAccounts.first(where: \.isTiedBest)?.markupPct,
              let worstAccount = ranking.rankedAccounts.last,
              worstAccount.isTiedBest == false,
              worstAccount.markupPct > best else { return nil }
        let spend = tripTxs(live)
            .filter {
                $0.linkedAccountId == worstAccount.linkedAccountId
                    && $0.isMarkupCalculable
                    && $0.billedCurrency == ranking.destinationCurrency
            }
            .reduce(0) { $0 + $1.homeCurrencyAmount }
        let saved = spend * (worstAccount.markupPct - best) / 100
        return saved >= 1 ? saved : nil
    }

    @ViewBuilder
    private var advisorSection: some View {
        if let currency = advisorCurrency {
            if let ranking = appStore.cardRankings.first(where: { $0.destinationCurrency == currency }) {
                advisorCard(ranking: ranking, currency: currency)
            } else {
                advisorFallbackCard(currency: currency)
            }
        }
    }

    private func advisorCard(ranking: CardRanking, currency: String) -> some View {
        let place = advisorPlace(for: currency)
        let accounts = appStore.linkedAccounts
        let tiedBest = ranking.rankedAccounts.filter(\.isTiedBest)
        let isTied = tiedBest.count > 1
        let bestName = tiedBest.first
            .flatMap { r in accounts.first { $0.id == r.linkedAccountId }?.displayName } ?? "your best card"
        let tiedNames = tiedBest.compactMap { ranked in
            accounts.first { $0.id == ranked.linkedAccountId }?.displayName
        }.joined(separator: " and ")
        let worst = ranking.rankedAccounts.last
        let worstName = worst
            .flatMap { r in accounts.first { $0.id == r.linkedAccountId }?.displayName } ?? "your worst"

        return VStack(alignment: .leading, spacing: 0) {
            sectionEyebrow(advisorHeading(
                evidenceTier: ranking.evidenceTier,
                isTied: isTied,
                place: place
            ))

            // The active recommendation, not a passive table.
            Group {
                if isTied {
                    Text(tiedRecommendationCopy(
                        names: tiedNames,
                        ranking: ranking
                    ))
                } else {
                    (
                        Text("Pay with \(Text(bestName).fontWeight(.bold).foregroundStyle(Theme.cream)) — ")
                        + Text(advisorSavingsLine(ranking: ranking, worstName: worstName, worstPct: worst?.markupPct))
                    )
                }
            }
                .font(.app(13.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 10)

            VStack(spacing: 10) {
                ForEach(Array(ranking.rankedAccounts.enumerated()), id: \.offset) { index, ranked in
                    rankedRow(
                        index: index, ranked: ranked,
                        isSoleWinner: ranked.isTiedBest && tiedBest.count == 1,
                        currency: ranking.destinationCurrency,
                        evidenceTier: ranking.evidenceTier
                    )
                }
            }
            .padding(.top, 16)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.vertical, 16)

            dccScriptBlock(currency: currency)

            Button { showWhichCard = true } label: {
                HStack(spacing: 6) {
                    Text("Heading somewhere else?")
                        .font(.app(11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.98))
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .surfaceCard()
    }

    private func advisorSavingsLine(ranking: CardRanking, worstName: String, worstPct: Double?) -> String {
        guard ranking.rankedAccounts.filter(\.isTiedBest).count == 1 else {
            return "jointly best observed; there isn't enough separation to promise a saving."
        }
        let bestPct = ranking.rankedAccounts.first(where: \.isTiedBest)?.markupPct ?? 0
        if ranking.evidenceTier == .verifiedCrossCurrency {
            return "it has the lowest typical markup across your verified FX history elsewhere. Treat this as a limited guide for this destination."
        }
        if ranking.evidenceTier == .provisionalDestination {
            return "it has the lowest provisional estimate for this currency. The result updates automatically when ECB data is available."
        }
        if let saved = advisorTripSavings(ranking) {
            return "on a trip like this one, that's ≈\(Derive.fmtMoney(saved)) kept instead of skimmed."
        }
        if let worstPct, worstPct > bestPct {
            return "it costs \(Derive.fmtPct(bestPct)) in markup vs \(Derive.fmtPct(worstPct)) on \(worstName)."
        }
        return "the cheapest card you own for this currency."
    }

    private func tiedRecommendationCopy(names: String, ranking: CardRanking) -> String {
        switch ranking.evidenceTier {
        case .verifiedDestination:
            return "\(names) are jointly best observed. Their typical FX costs are within 0.05 percentage points, so Skimmed won't invent a winner."
        case .verifiedCrossCurrency:
            return "\(names) are jointly lowest across your verified FX history elsewhere. This is limited guidance for the selected destination."
        case .provisionalDestination:
            return "\(names) are jointly lowest on provisional estimates. Skimmed won't invent a winner, and the result updates automatically."
        }
    }

    /// Honest state when only one card has been seen in the advised currency
    /// — no fake ranking, just the way to get one.
    private func advisorFallbackCard(currency: String) -> some View {
        let place = advisorPlace(for: currency)
        return VStack(alignment: .leading, spacing: 0) {
            sectionEyebrow("NEED MORE EVIDENCE — \(place)")

            Text("Only one card on file for \(currency) — import a statement from another card to see which one actually costs you less.")
                .font(.app(12.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 10)

            HStack {
                AddStatementPill()
                Spacer()
            }
            .padding(.top, 14)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.vertical, 16)

            dccScriptBlock(currency: currency)

            Button { showWhichCard = true } label: {
                HStack(spacing: 6) {
                    Text("Heading somewhere else?")
                        .font(.app(11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.98))
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .surfaceCard()
    }

    private func advisorPlace(for currency: String) -> String {
        for destination in destinations {
            if let info = Derive.destinationInfo(destination), info.currency == currency {
                return "\(destination) \(Derive.flag(info.country))"
            }
        }
        return currency
    }

    private func sectionEyebrow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)
        }
    }

    private func rankedRow(
        index: Int,
        ranked: RankedAccount,
        isSoleWinner: Bool,
        currency: String,
        evidenceTier: RecommendationEvidenceTier
    ) -> some View {
        let account = appStore.linkedAccounts.first { $0.id == ranked.linkedAccountId }
        let isBest = ranked.isTiedBest
        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.app(11, weight: .bold))
                .foregroundStyle(isBest ? Theme.onAccent : Theme.muted)
                .frame(width: 24, height: 24)
                .background(isBest ? Theme.accent : Color.white.opacity(0.1), in: Circle())

            BankMark(bank: account?.institutionName ?? "—", size: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text(account?.displayName ?? "Unknown card")
                        .font(.app(13, weight: .bold))
                        .foregroundStyle(Theme.cream)
                    if let account {
                        Text("  ···· \(account.last4)")
                            .font(.app(10.5, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }
                }
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
                    .font(.app(isSoleWinner ? 9.5 : 8.5, weight: .heavy))
                    .kerning(0.5)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(14)
        .background(
            isBest ? Theme.accent.opacity(0.1) : Color.white.opacity(0.02),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isBest ? Theme.accent.opacity(0.6) : Color.white.opacity(0.05),
                    lineWidth: 1
                )
        )
    }

    private func advisorHeading(
        evidenceTier: RecommendationEvidenceTier,
        isTied: Bool,
        place: String
    ) -> String {
        switch evidenceTier {
        case .verifiedDestination:
            return "\(isTied ? "JOINT BEST OBSERVED" : "BEST OBSERVED") — \(place)"
        case .verifiedCrossCurrency:
            return "\(isTied ? "JOINT LIMITED GUIDE" : "LIMITED GUIDE") — \(place)"
        case .provisionalDestination:
            return "\(isTied ? "JOINT PROVISIONAL GUIDE" : "PROVISIONAL GUIDE") — \(place)"
        }
    }

    private func winnerLabel(
        evidenceTier: RecommendationEvidenceTier,
        isSoleWinner: Bool
    ) -> String {
        switch evidenceTier {
        case .verifiedDestination:
            return isSoleWinner ? "USE THIS" : "JOINT BEST"
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

    // MARK: - DCC refusal script

    /// The DCC refusal script, adapted to the advised destination currency —
    /// lives inside the advisor card so "which card" and "what to say at the
    /// terminal" arrive as one trip-solve moment.
    private func dccScriptBlock(currency: String) -> some View {
        let script = "In \(Derive.currencySpokenName(currency)), please — no conversion."
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text("IF THE TERMINAL ASKS \"PAY IN \(storedHomeCurrency)?\"")
                    .font(.app(10, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.muted)
            }

            Text("\u{201C}\(script)\u{201D}")
                .font(.app(15, weight: .semibold))
                .foregroundStyle(Theme.cream)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.accent)
                        .frame(width: 2)
                }
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("· Always choose \(currency) over \(storedHomeCurrency) at the terminal.")
                Text("· Already charged in \(storedHomeCurrency)? Ask them to void and re-run it.")
                Text("· DCC adds 4–8% per Visa's own published data.")
            }
            .font(.app(11.5))
            .foregroundStyle(Theme.muted)
            .lineSpacing(3)
            .padding(.top, 12)

            Button {
                UIPasteboard.general.string = script
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation(.easeOut(duration: 0.15)) { copied = false }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(copied ? Theme.good : Theme.cream.opacity(0.9))
                    Text(copied ? "Copied" : "Copy script")
                        .font(.app(12, weight: .bold))
                        .foregroundStyle(Theme.cream.opacity(0.9))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .sensoryFeedback(.success, trigger: copied) { _, new in new }
            .padding(.top, 16)
        }
    }

    // MARK: - Latest finds

    private var latestFindsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recentFinds.isEmpty {
                Text("No charges yet — import a statement to see your latest finds here.")
                    .font(.app(12))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 14) {
                    ForEach(recentFinds) { tx in
                        TxRow(tx: tx, blurAmount: blurLoss, onTap: { selectedTx = tx })
                    }
                }
            }

            Text("Scanned \(appStore.revealSnapshot.transactionCount) foreign charges since \(Derive.fmtDate(appStore.revealSnapshot.periodStart))")
                .font(.app(11))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
        .padding(20)
        .surfaceCard()
    }
}

private struct OverviewMetricCard: View {
    let label: String
    let value: String
    let badge: String
    let icon: String
    let tint: Color
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(label)
                    .font(.app(10.5, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)

                Spacer()

                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 23, height: 23)
                        .background(Color.white.opacity(0.055), in: Circle())
                }
                .buttonStyle(PressStyle(scale: 0.88))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.app(24, weight: .heavy))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }

            Text(badge)
                .font(.app(9.5, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.13), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .surfaceCard(cornerRadius: 18)
    }
}

/// Compact, honest purchase surface reachable from Home's unlock banner —
/// same products/prices as `RevealView`'s real paywall (via `EntitlementStore`
/// directly), just a smaller presentation so Home never feels like a second
/// full paywall. Never renders a hard-coded price.
private struct UnlockReportSheet: View {
    @ObservedObject private var entitlements = EntitlementStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing = false

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Unlock your full report")
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

                if entitlements.products.isEmpty {
                    Text(entitlements.loadError ? "Purchases unavailable right now." : "Loading…")
                        .font(.app(12.5))
                        .foregroundStyle(Theme.muted)
                } else {
                    ForEach(entitlements.products, id: \.id) { product in
                        Button {
                            purchasing = true
                            Task {
                                try? await entitlements.purchase(product)
                                purchasing = false
                                if entitlements.hasFullAccess { dismiss() }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.displayName)
                                        .font(.app(13, weight: .bold))
                                        .foregroundStyle(Theme.cream)
                                }
                                Spacer()
                                Text(product.displayPrice)
                                    .font(.app(13, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                            }
                            .padding(16)
                            .surfaceCard(cornerRadius: 16)
                        }
                        .buttonStyle(PressStyle(scale: 0.98))
                        .disabled(purchasing)
                    }
                }

                Button {
                    Task { await entitlements.restore() }
                } label: {
                    Text("Restore purchases")
                        .font(.app(12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .underline()
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(20)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
