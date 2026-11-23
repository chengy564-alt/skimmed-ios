import SwiftUI
import PhotosUI

/// Profile — account, plan, linked accounts, travel profile, region, and
/// deep links into Settings. Linked accounts read `AppStore` (imported
/// cards); travel frequency/destinations read/write the same `@AppStorage`
/// keys onboarding writes; plan state comes from `EntitlementStore`, never
/// a fabricated tier.
struct ProfileView: View {

    @ObservedObject private var entitlements = EntitlementStore.shared
    @ObservedObject private var appStore = AppStore.shared

    @AppStorage("profile.name") private var storedName: String = ""
    @AppStorage("profile.tripFreq") private var storedTripFreq: String = ""
    @AppStorage("profile.destinations") private var storedDestinations: String = ""
    @AppStorage("profile.homeCountry") private var storedHomeCountry: String = HomeRegion.defaultCountry
    @AppStorage("profile.homeCurrency") private var storedHomeCurrency: String = RateProvider.defaultHomeCurrency

    /// "Skimmed 1.0 (3)" — read from the bundle so it's always the real
    /// shipped version, never a stale hardcoded label.
    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Skimmed \(version)" : "Skimmed \(version) (\(build))"
    }

    /// Real plan state from StoreKit entitlements.
    private var planBadge: String {
        if entitlements.isPlus { return "PLUS" }
        if entitlements.hasFullAccess { return "FULL REPORT" }
        return "FREE"
    }

    @State private var appeared = false
    @State private var settingsRoute: SettingsRoute? = nil
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showFreqSheet = false
    @State private var showDestinationsSheet = false
    @State private var showRegionSheet = false
    @State private var showWaitlistSheet = false
    @State private var waitlistEntry: WaitlistEntry? = WaitlistService.lastSubmission()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                hero

                subscriptionCard

                sectionLabel("YOUR TRAVEL PROFILE")
                travelProfileCard

                sectionLabel("LINKED ACCOUNTS")
                accountsCard

                if let waitlistEntry {
                    sectionLabel("WAITLIST")
                    waitlistCard(waitlistEntry)
                }

                sectionLabel("SETTINGS")
                settingsCard

                Text(Self.versionLabel)
                    .font(.app(10))
                    .foregroundStyle(Theme.muted.opacity(0.7))
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 140) // room for the floating nav
        }
        .fullScreenCover(item: $settingsRoute) { route in
            SettingsView(initialRoute: route)
        }
        .sheet(isPresented: $showFreqSheet) {
            TravelFreqSheet(storedTripFreq: $storedTripFreq)
        }
        .sheet(isPresented: $showDestinationsSheet) {
            DestinationsSheet(storedDestinations: $storedDestinations)
        }
        .sheet(isPresented: $showRegionSheet) {
            RegionSheet(storedHomeCountry: $storedHomeCountry, storedHomeCurrency: $storedHomeCurrency)
        }
        .sheet(isPresented: $showWaitlistSheet, onDismiss: {
            waitlistEntry = WaitlistService.lastSubmission()
        }) {
            WaitlistSheet(submitter: WaitlistService(), prefillEntry: waitlistEntry)
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        AvatarStore.shared.save(uiImage)
                    }
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45).delay(0.05)) { appeared = true }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    AvatarView(size: 56)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 18, height: 18)
                                .background(Theme.accent, in: Circle())
                                .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                                .offset(x: 2, y: 2)
                        }
                }
                .buttonStyle(PressStyle(scale: 0.94))

                Spacer()

                Text(planBadge)
                    .font(.app(9.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
            }

            Text(storedName.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Hello"
                : "Hello, \(storedName.trimmingCharacters(in: .whitespaces))")
                .font(.app(30, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .padding(.top, 18)

            Text("\(storedHomeCurrency) travel wallet · \(Derive.countryName(storedHomeCountry)) \(Derive.flag(storedHomeCountry))")
                .font(.app(12))
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)

            if entitlements.isSupporter {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9))
                    Text("FOUNDING SUPPORTER")
                        .font(.app(9.5, weight: .bold))
                        .kerning(0.4)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.accent.opacity(0.15), in: Capsule())
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background {
            ZStack(alignment: .topTrailing) {
                Theme.surface
                RadialGradient(
                    colors: [Theme.accentHot.opacity(0.3), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 130
                )
                .frame(width: 260, height: 260)
                .blur(radius: 34)
                .offset(x: 70, y: -70)
                RadialGradient(
                    colors: [Theme.loss.opacity(0.12), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 100
                )
                .frame(width: 200, height: 200)
                .blur(radius: 30)
                .offset(x: -90, y: 80)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 10)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.app(13, weight: .bold))
            .kerning(1.4)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 8)
    }

    // MARK: - Plan (real entitlement state, never a fabricated tier)

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PLAN")
                    .font(.app(10, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text(planBadge)
                    .font(.app(9.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
            }

            Text(planHeadline)
                .font(.app(22, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .padding(.top, 10)

            Text(planSubline)
                .font(.app(11.5))
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .surfaceCard(cornerRadius: 20)
    }

    private var planHeadline: String {
        if entitlements.isPlus { return "Skimmed Plus" }
        if entitlements.hasFullAccess { return "Full report" }
        return "Free"
    }

    private var planSubline: String {
        if entitlements.isPlus {
            return "Unlimited imports, every card, reports always up to date. Manage in Settings → Subscriptions."
        }
        if entitlements.hasFullAccess {
            return "One-time unlock — your full report, yours for good."
        }
        return "Import a statement and unlock your full report any time."
    }

    // MARK: - Linked accounts

    private var accountsCard: some View {
        let accounts = appStore.linkedAccounts
        return VStack(spacing: 0) {
            if accounts.isEmpty {
                Text("No cards yet — import a statement to add one.")
                    .font(.app(12))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 12)
            }
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                HStack(spacing: 12) {
                    BankMark(bank: account.institutionName, size: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .font(.app(13, weight: .bold))
                            .foregroundStyle(Theme.cream)
                        Text("···· \(account.last4) · \(account.accountType == .credit ? "Credit" : "Debit")")
                            .font(.app(10.5))
                            .foregroundStyle(Theme.muted)
                    }

                    Spacer(minLength: 8)

                    Text(account.status == .active ? "ACTIVE" : "RELINK")
                        .font(.app(9, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(account.status == .active ? Theme.good : Theme.loss)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            (account.status == .active ? Theme.good : Theme.loss).opacity(0.13),
                            in: Capsule()
                        )
                }
                .padding(.vertical, 12)

                if index != accounts.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                }
            }

            Text("Analysed on-device from your statements.")
                .font(.app(10))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .surfaceCard(cornerRadius: 20)
    }

    // MARK: - Travel profile (onboarding answers, editable)

    private var travelProfileCard: some View {
        VStack(spacing: 0) {
            Button { showFreqSheet = true } label: {
                profileRow(
                    icon: "airplane",
                    label: "Travel frequency",
                    value: TripFreqBucket(rawValue: storedTripFreq).map(freqLabel) ?? "Not set"
                )
            }
            .buttonStyle(PressStyle(scale: 0.98))

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            Button { showDestinationsSheet = true } label: {
                profileRow(
                    icon: "map.fill",
                    label: "Usual destinations",
                    value: storedDestinations.isEmpty
                        ? "Not set"
                        : storedDestinations.split(separator: ",").joined(separator: ", ")
                )
            }
            .buttonStyle(PressStyle(scale: 0.98))

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            Button { showRegionSheet = true } label: {
                profileRow(
                    icon: "globe.asia.australia.fill",
                    label: "Home region",
                    value: "\(Derive.flag(storedHomeCountry)) \(HomeRegion.name(forCountry: storedHomeCountry)) · \(storedHomeCurrency)"
                )
            }
            .buttonStyle(PressStyle(scale: 0.98))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .surfaceCard(cornerRadius: 20)
    }

    private func freqLabel(_ bucket: TripFreqBucket) -> String {
        bucket.caption
    }

    private func profileRow(icon: String, label: String, value: String) -> some View {
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
                Text(value)
                    .font(.app(10.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
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

    // MARK: - Waitlist (only shown once the user has joined — B7)

    private func waitlistCard(_ entry: WaitlistEntry) -> some View {
        Button { showWaitlistSheet = true } label: {
            profileRow(
                icon: "bell.badge.fill",
                label: "Automatic connection waitlist · \(entry.bank)",
                value: "Notify for \(entry.country) — tap to edit or leave"
            )
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .surfaceCard(cornerRadius: 20)
    }

    // MARK: - Settings (deep links into SettingsView)

    private struct SettingRow: Identifiable {
        let id: String
        let icon: String
        let label: String
    }

    private let settings: [SettingRow] = [
        SettingRow(id: "notifications", icon: "bell.fill", label: "Notifications"),
        SettingRow(id: "privacy", icon: "lock.fill", label: "Security & privacy"),
        SettingRow(id: "help", icon: "questionmark.circle.fill", label: "Help & support"),
    ]

    private var settingsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(settings.enumerated()), id: \.element.id) { index, row in
                Button {
                    settingsRoute = SettingsRoute(rawValue: row.id) ?? .help
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: row.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent.opacity(0.12), in: Circle())

                        Text(row.label)
                            .font(.app(13, weight: .semibold))
                            .foregroundStyle(Theme.cream)

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

                if index != settings.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .surfaceCard(cornerRadius: 20)
    }
}

// MARK: - Travel frequency editor (same 4-option pattern as onboarding Q1)

private struct TravelFreqSheet: View {
    @Binding var storedTripFreq: String
    @Environment(\.dismiss) private var dismiss

    private let copy = Copy.active

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Travel frequency")
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

                Text(copy.s3Q1)
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream.opacity(0.9))

                VStack(spacing: 10) {
                    ForEach(Array(copy.s3FreqChips.enumerated()), id: \.offset) { _, chip in
                        Chip(label: chip.label, isOn: storedTripFreq == chip.value.rawValue) {
                            storedTripFreq = chip.value.rawValue
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer()
            }
            .padding(20)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Usual destinations editor (same chip pattern as onboarding Q2)

private struct DestinationsSheet: View {
    @Binding var storedDestinations: String
    @Environment(\.dismiss) private var dismiss

    private let region = RegionCatalog.activeRegion

    @State private var selected: Set<String> = []

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Usual destinations")
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

                Text("Where do you usually go?")
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream.opacity(0.9))

                CountrySelectField(selection: $selected)

                if !selected.isEmpty {
                    ScrollView(showsIndicators: false) {
                        FlowLayout(spacing: 8) {
                            ForEach(selected.sorted(), id: \.self) { code in
                                Button {
                                    _ = selected.remove(code)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("\(Derive.flag(code)) \(CountryCatalog.name(for: code))")
                                            .font(.app(12, weight: .semibold))
                                            .foregroundStyle(Theme.cream)
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.muted)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Spacer()

                PrimaryButton(title: "Save", trailingIcon: nil, isDisabled: selected.isEmpty) {
                    storedDestinations = selected.joined(separator: ",")
                    dismiss()
                }
            }
            .padding(20)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            selected = Set(storedDestinations
                .split(separator: ",")
                .map(String.init)
                .compactMap { token in
                    let t = token.trimmingCharacters(in: .whitespaces)
                    if t.count == 2, t.uppercased().allSatisfy({ $0.isASCII && $0.isLetter }) { return t.uppercased() }
                    return Derive.destinationInfo(t)?.country // migrate legacy labels
                })
        }
    }
}

// MARK: - Home region editor (Profile + Settings share this one sheet)

/// Not `private` — `SettingsView`'s Region & currency page presents the same
/// sheet rather than re-declaring it, so there's exactly one editor for
/// `profile.homeCountry` / `profile.homeCurrency` in the app.
struct RegionSheet: View {
    @Binding var storedHomeCountry: String
    @Binding var storedHomeCurrency: String
    @ObservedObject private var appStore = AppStore.shared
    @Environment(\.dismiss) private var dismiss

    private static let currencyOptions = RateTable.toHKD.keys.sorted()

    @State private var selectedCountry: String
    @State private var selectedCurrency: String
    @State private var isOther: Bool
    @State private var otherCountry: String
    @State private var otherCurrency: String

    init(storedHomeCountry: Binding<String>, storedHomeCurrency: Binding<String>) {
        _storedHomeCountry = storedHomeCountry
        _storedHomeCurrency = storedHomeCurrency
        let matched = HomeRegion.options.first {
            $0.country == storedHomeCountry.wrappedValue && $0.currency == storedHomeCurrency.wrappedValue
        }
        _selectedCountry = State(initialValue: matched?.country ?? HomeRegion.options[0].country)
        _selectedCurrency = State(initialValue: matched?.currency ?? HomeRegion.options[0].currency)
        _isOther = State(initialValue: matched == nil)
        _otherCountry = State(initialValue: matched == nil ? storedHomeCountry.wrappedValue : "")
        _otherCurrency = State(initialValue: matched == nil ? storedHomeCurrency.wrappedValue : Self.currencyOptions.first ?? "USD")
    }

    private var trimmedOtherCountry: String {
        otherCountry.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var canSave: Bool {
        (!isOther || !trimmedOtherCountry.isEmpty) && !currencyChangeBlocked
    }

    private var proposedCurrency: String {
        isOther ? otherCurrency : selectedCurrency
    }

    private var currencyChangeBlocked: Bool {
        appStore.importedDataHomeCurrency != nil
            && proposedCurrency != storedHomeCurrency
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Home region")
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

                Text("Where do you call home?")
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream.opacity(0.9))

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(HomeRegion.options) { option in
                            regionRow(option)
                        }
                        otherRow
                    }
                }

                Text(currencyChangeBlocked
                    ? "Your imported results are in \(storedHomeCurrency). Delete imported data before changing currency, so unlike currencies are never relabelled or added together."
                    : appStore.importedDataHomeCurrency == nil
                        ? "This sets the currency used for loss calculations on new imports."
                        : "You can change country while keeping \(storedHomeCurrency). Home currency stays locked while imported data is present.")
                    .font(.app(10.5))
                    .foregroundStyle(currencyChangeBlocked ? Theme.accent : Theme.muted)
                    .lineSpacing(3)

                PrimaryButton(title: "Save", trailingIcon: nil, isDisabled: !canSave) {
                    if isOther {
                        storedHomeCountry = trimmedOtherCountry
                        storedHomeCurrency = otherCurrency
                    } else {
                        storedHomeCountry = selectedCountry
                        storedHomeCurrency = selectedCurrency
                    }
                    dismiss()
                }
            }
            .padding(20)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func regionRow(_ option: HomeRegion.Option) -> some View {
        let isSelected = !isOther && selectedCountry == option.country && selectedCurrency == option.currency
        return Button {
            isOther = false
            selectedCountry = option.country
            selectedCurrency = option.currency
        } label: {
            HStack(spacing: 12) {
                Text(Derive.flag(option.country))
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(Theme.cream)
                    Text(option.currency)
                        .font(.app(10.5))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }

    private var otherRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                isOther = true
            } label: {
                HStack(spacing: 12) {
                    Text("🏳️")
                        .font(.system(size: 22))
                    Text("Other")
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(Theme.cream)
                    Spacer()
                    if isOther {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOther {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("COUNTRY CODE")
                            .font(.app(10, weight: .semibold))
                            .kerning(1)
                            .foregroundStyle(Theme.muted)
                        TextField("e.g. NZ", text: $otherCountry)
                            .font(.app(13, weight: .semibold))
                            .foregroundStyle(Theme.cream)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("CURRENCY")
                            .font(.app(10, weight: .semibold))
                            .kerning(1)
                            .foregroundStyle(Theme.muted)
                        Menu {
                            ForEach(Self.currencyOptions, id: \.self) { code in
                                Button(code) { otherCurrency = code }
                            }
                        } label: {
                            HStack {
                                Text(otherCurrency)
                                    .font(.app(13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isOther ? Theme.accent.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}
