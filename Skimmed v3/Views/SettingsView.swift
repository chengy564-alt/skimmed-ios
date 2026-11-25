import Combine
import StoreKit
import SwiftUI

/// Hierarchical settings in Skimmed's own skin — stock nav bar hidden,
/// custom back chevron, surfaceCard rows. Toggles persist via @AppStorage.
/// Reachable from Home's gear (main list) and Profile's rows (deep-linked).

enum SettingsRoute: String, Hashable, CaseIterable, Identifiable {
    case notifications, privacy, region, purchases, help, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: return "Notifications"
        case .privacy: return "Security & privacy"
        case .region: return "Region & currency"
        case .purchases: return "Purchases"
        case .help: return "Help & support"
        case .about: return "About Skimmed"
        }
    }

    var icon: String {
        switch self {
        case .notifications: return "bell.fill"
        case .privacy: return "lock.fill"
        case .region: return "globe.asia.australia.fill"
        case .purchases: return "creditcard.fill"
        case .help: return "questionmark.circle.fill"
        case .about: return "info.circle.fill"
        }
    }

    var sub: String {
        switch self {
        case .notifications: return "Trip alerts, new charges, reports"
        case .privacy: return "Face ID, haptics, your data"
        case .region:
            let country = UserDefaults.standard.string(forKey: "profile.homeCountry") ?? HomeRegion.defaultCountry
            let currency = UserDefaults.standard.string(forKey: "profile.homeCurrency") ?? RateProvider.defaultHomeCurrency
            return "\(Derive.flag(country)) \(HomeRegion.name(forCountry: country)) · \(currency)"
        case .purchases: return "Full report, Plus & restore"
        case .help: return "FAQ and contact"
        case .about: return "Version and methodology"
        }
    }
}

struct SettingsView: View {
    var initialRoute: SettingsRoute? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AppBackdrop()
                mainList
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SettingsRoute.self) { route in
                ZStack {
                    AppBackdrop()
                    subPage(route)
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .onAppear {
            if let initialRoute { path = [initialRoute] }
        }
    }

    // MARK: - Main list

    private var mainList: some View {
        VStack(spacing: 0) {
            header(title: "Settings", isRoot: true)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(SettingsRoute.allCases.enumerated()), id: \.element) { index, route in
                        Button {
                            path.append(route)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: route.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 32, height: 32)
                                    .background(Theme.accent.opacity(0.12), in: Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(route.title)
                                        .font(.app(13, weight: .semibold))
                                        .foregroundStyle(Theme.cream)
                                    Text(route.sub)
                                        .font(.app(10.5))
                                        .foregroundStyle(Theme.muted)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle(scale: 0.98))

                        if index != SettingsRoute.allCases.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .surfaceCard(cornerRadius: 20)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
    }

    // MARK: - Sub-pages

    @ViewBuilder
    private func subPage(_ route: SettingsRoute) -> some View {
        VStack(spacing: 0) {
            header(title: route.title, isRoot: false)

            ScrollView(showsIndicators: false) {
                Group {
                    switch route {
                    case .notifications: NotificationsSettings()
                    case .privacy: PrivacySettings()
                    case .region: RegionSettings()
                    case .purchases: PurchasesSettings()
                    case .help: HelpSettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Custom header (back chevron / close)

    private func header(title: String, isRoot: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                if isRoot {
                    dismiss()
                } else {
                    // Pops to the main list — including from a deep-linked
                    // entry, so Profile's shortcuts still surface the rest
                    // of Settings on the way out.
                    path.removeLast()
                }
            } label: {
                Image(systemName: isRoot ? "xmark" : "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.cream)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            Text(title)
                .font(.app(20, weight: .heavy))
                .foregroundStyle(Theme.cream)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

// MARK: - Shared rows

private struct SettingsToggleRow: View {
    let icon: String
    let label: String
    let sub: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                Text(sub)
                    .font(.app(10.5))
                    .foregroundStyle(Theme.muted)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.vertical, 12)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }
}

// MARK: - Notifications

private struct NotificationsSettings: View {
    @AppStorage("settings.tripAlerts") private var tripAlerts = true
    @AppStorage("settings.newChargeFlags") private var newChargeFlags = true
    @AppStorage("settings.monthlyReport") private var monthlyReport = true
    @AppStorage("settings.weeklyDigest") private var weeklyDigest = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                icon: "airplane",
                label: "Trip alerts",
                sub: "The moment a trip is detected",
                isOn: $tripAlerts
            )
            SettingsDivider()
            SettingsToggleRow(
                icon: "flame.fill",
                label: "New-charge flags",
                sub: "Bad rates flagged when you upload",
                isOn: $newChargeFlags
            )
            SettingsDivider()
            SettingsToggleRow(
                icon: "calendar",
                label: "Monthly damage report",
                sub: "1st of every month",
                isOn: $monthlyReport
            )
            SettingsDivider()
            SettingsToggleRow(
                icon: "envelope.fill",
                label: "Weekly digest",
                sub: "A quieter summary, every Sunday",
                isOn: $weeklyDigest
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .surfaceCard(cornerRadius: 20)
    }
}

// MARK: - Security & privacy

private struct PrivacySettings: View {
    @AppStorage("settings.biometricLock") private var biometricLock = false
    @AppStorage("settings.haptics") private var haptics = true
    @ObservedObject private var appStore = AppStore.shared
    @State private var confirmDelete = false
    @State private var confirmClearHistory = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    icon: "faceid",
                    label: "Face ID lock",
                    sub: "Require Face ID to open Skimmed",
                    isOn: $biometricLock
                )
                SettingsDivider()
                SettingsToggleRow(
                    icon: "hand.tap.fill",
                    label: "Haptics",
                    sub: "Taps, ticks, and unlock thumps",
                    isOn: $haptics
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .surfaceCard(cornerRadius: 20)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.good)
                Text("Your statements are analysed on this device. We never upload or store the raw file, and we can never move money.")
                    .font(.app(11.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .surfaceCard(cornerRadius: 18)

            if !appStore.hasNoData {
                Button {
                    confirmClearHistory = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Clear transaction history")
                            .font(.app(12.5, weight: .bold))
                    }
                    .foregroundStyle(Theme.loss)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.loss.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.loss.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .confirmationDialog(
                    "Clear transaction history?",
                    isPresented: $confirmClearHistory,
                    titleVisibility: .visible
                ) {
                    Button("Clear history", role: .destructive) {
                        appStore.clearTransactionHistory()
                    }
                    Button("Keep my data", role: .cancel) {}
                } message: {
                    Text("Removes every imported charge but keeps your cards. Import a statement to rebuild your report.")
                }
            }

            Button {
                confirmDelete = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Delete imported data")
                        .font(.app(12.5, weight: .bold))
                }
                .foregroundStyle(Theme.loss)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.loss.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.loss.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .confirmationDialog(
                "Delete all imported data?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) {
                    appStore.resetAllData()
                }
                Button("Keep my data", role: .cancel) {}
            } message: {
                Text("This deletes every imported card and charge. Statement files were never stored, so there's nothing else to remove. You can import again any time.")
            }
        }
    }
}

// MARK: - Region & currency

private struct RegionSettings: View {
    @ObservedObject private var appStore = AppStore.shared
    @AppStorage("profile.homeCountry") private var homeCountry: String = HomeRegion.defaultCountry
    @AppStorage("profile.homeCurrency") private var homeCurrency: String = RateProvider.defaultHomeCurrency
    @State private var showEditSheet = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("YOUR REGION")
                    .font(.app(10, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.muted)

                HStack(spacing: 12) {
                    Text(Derive.flag(homeCountry))
                        .font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HomeRegion.name(forCountry: homeCountry))
                            .font(.app(16, weight: .heavy))
                            .foregroundStyle(Theme.cream)
                        Text("All losses measured in \(homeCurrency)")
                            .font(.app(11))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(.top, 12)

                Text(appStore.importedDataHomeCurrency == nil
                    ? "Editable before your first import. This currency will measure every loss."
                    : "Home currency is locked while imported data is present, so unlike currencies are never relabelled or added together.")
                    .font(.app(10.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .surfaceCard(cornerRadius: 20)

            Button {
                showEditSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent.opacity(0.12), in: Circle())
                    Text("Change home region")
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(Theme.cream)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .surfaceCard(cornerRadius: 20)
            }
            .buttonStyle(PressStyle(scale: 0.98))
        }
        .sheet(isPresented: $showEditSheet) {
            RegionSheet(storedHomeCountry: $homeCountry, storedHomeCurrency: $homeCurrency)
        }
    }
}

// MARK: - Purchases

private struct PurchasesSettings: View {
    @ObservedObject private var entitlements = EntitlementStore.shared
    @Environment(\.openURL) private var openURL
    @State private var restoring = false
    @State private var restoreMessage: String? = nil

    private var planLabel: String {
        if entitlements.isPlus { return "Skimmed Plus" }
        if entitlements.unlockedReport { return "Full report unlocked" }
        return "No purchase yet"
    }

    private var planSub: String {
        if entitlements.isPlus { return "Auto-renewing annual plan" }
        if entitlements.unlockedReport { return "One-time unlock — yours for good" }
        return "Unlock your full report from the Reveal"
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("CURRENT PLAN")
                    .font(.app(10, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.muted)

                HStack(spacing: 12) {
                    Image(systemName: entitlements.hasFullAccess ? "checkmark.seal.fill" : "lock.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(entitlements.hasFullAccess ? Theme.good : Theme.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(planLabel)
                            .font(.app(15, weight: .bold))
                            .foregroundStyle(Theme.cream)
                        Text(planSub)
                            .font(.app(11))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(.top, 12)

                if entitlements.isSupporter {
                    Text("Founding supporter — thank you.")
                        .font(.app(11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .surfaceCard(cornerRadius: 20)

            VStack(spacing: 0) {
                Button {
                    Task {
                        restoring = true
                        await entitlements.restore()
                        restoring = false
                        restoreMessage = (entitlements.hasFullAccess || entitlements.isSupporter)
                            ? "Restored successfully."
                            : "No previous purchases found."
                    }
                } label: {
                    purchaseRow(icon: "arrow.clockwise", label: "Restore purchases", trailing: restoring ? "…" : nil)
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .disabled(restoring)

                SettingsDivider()

                Button {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        openURL(url)
                    }
                } label: {
                    purchaseRow(icon: "gearshape.fill", label: "Manage subscription", trailing: nil)
                }
                .buttonStyle(PressStyle(scale: 0.98))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .surfaceCard(cornerRadius: 20)

            if let restoreMessage {
                Text(restoreMessage)
                    .font(.app(11.5))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func purchaseRow(icon: String, label: String, trailing: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.12), in: Circle())

            Text(label)
                .font(.app(13, weight: .semibold))
                .foregroundStyle(Theme.cream)

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.app(12))
                    .foregroundStyle(Theme.muted)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Help & support

private struct HelpSettings: View {
    @State private var expanded: String? = nil

    private let faqs: [(q: String, a: String)] = [
        (
            "How do you know what I actually lost?",
            "We compare foreign transactions that contain enough statement detail with a date-matched reference rate. Verified calculations use free ECB data; an offline estimate is labelled and updates automatically."
        ),
        (
            "Can Skimmed move my money?",
            "No. Skimmed only reads the statement you choose to import, analyses it on this device, and never stores the raw file. We can never touch your money."
        ),
        (
            "What's a DCC trap?",
            "When a foreign terminal offers to charge you in \(Derive.homeCurrencyCode) instead of the local currency. It feels helpful — and adds 4–8% per Visa's own published data. Always pick the local currency."
        ),
    ]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                ForEach(Array(faqs.enumerated()), id: \.element.q) { index, faq in
                    faqRow(faq)
                    if index != faqs.count - 1 {
                        SettingsDivider()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .surfaceCard(cornerRadius: 20)

            Link(destination: URL(string: "https://x.com/Skimmedapps")!) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Contact us")
                        .font(.app(12.5, weight: .bold))
                        .foregroundStyle(Theme.cream)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(18)
                .surfaceCard(cornerRadius: 18)
            }
        }
    }

    private func faqRow(_ faq: (q: String, a: String)) -> some View {
        let isOpen = expanded == faq.q
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    expanded = isOpen ? nil : faq.q
                }
            } label: {
                HStack {
                    Text(faq.q)
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(Theme.cream)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.99))

            if isOpen {
                Text(faq.a)
                    .font(.app(12))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .sensoryFeedback(.selection, trigger: isOpen)
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.accent)
                }
                Text("Skimmed")
                    .font(.app(18, weight: .heavy))
                    .foregroundStyle(Theme.cream)
                Text("Preview build · Hong Kong")
                    .font(.app(11))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .surfaceCard(cornerRadius: 20)

            VStack(alignment: .leading, spacing: 0) {
                Text("METHODOLOGY")
                    .font(.app(10, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.muted)
                Text(Copy.active.revealMethodology)
                    .font(.app(12))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .surfaceCard(cornerRadius: 20)

            #if DEBUG
            developerCard
            #endif
        }
    }

    #if DEBUG
    /// Developer-build-only full-access toggle so the owner can review the
    /// unlocked app without purchasing. Compiles out of release builds —
    /// customers can never reach this.
    @AppStorage("dev.unlockAll") private var devUnlockAll = false

    private var developerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DEVELOPER")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)

            SettingsToggleRow(
                icon: "hammer.fill",
                label: "Unlock everything",
                sub: "Debug builds only — never ships to customers",
                isOn: $devUnlockAll
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .surfaceCard(cornerRadius: 20)
        .onChange(of: devUnlockAll) { _, _ in
            // hasFullAccess reads this flag directly; poke observers so
            // gated views refresh the moment the toggle flips.
            EntitlementStore.shared.objectWillChange.send()
        }
    }
    #endif
}
