import StoreKit
import SwiftUI
import UniformTypeIdentifiers

/// Onboarding — 4 screens, HKD/HK region config (ported from
/// `app/onboarding/page.tsx`).
///
/// 1 invoke emotion → 2 demonstrate benefits → 3 personalize (2 questions +
/// statement import) → 4 scientific evidence (scan runs) → Reveal.
struct OnboardingView: View {
    var onFinished: () -> Void
    /// "Skip for now" on the import screen — no statement was imported, so
    /// there's nothing to reveal; the app routes straight to Home's empty
    /// state instead of the evidence/reveal screens.
    var onSkipped: () -> Void

    private enum Step: Equatable {
        case emotion, benefits, questions, importStep, evidence

        var dot: Int {
            switch self {
            case .emotion: return 1
            case .benefits: return 2
            case .questions, .importStep: return 3
            case .evidence: return 4
            }
        }
    }

    /// A statement picked from `.fileImporter`, read into memory once and
    /// never retained on disk. Identifiable so it can drive a
    /// `fullScreenCover(item:)`.
    private struct PickedFile: Identifiable {
        let id = UUID()
        let data: Data
        let filename: String
    }

    @State private var step: Step = .emotion

    // Step 3a answers (feed User.onboarding* fields)
    @State private var freq: TripFreqBucket? = nil
    @State private var dests: Set<String> = []

    // Step 3b — statement import
    @State private var pickedFile: PickedFile? = nil

    private let copy = Copy.active
    private let region = RegionCatalog.activeRegion

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 24)

            ZStack {
                switch step {
                case .emotion:
                    EmotionScreen(copy: copy) { advance(.benefits) }
                        .transition(slide)
                case .benefits:
                    BenefitsScreen(copy: copy) { advance(.questions) }
                        .transition(slide)
                case .questions:
                    QuestionsScreen(copy: copy, region: region, freq: $freq, dests: $dests) {
                        advance(.importStep)
                    }
                    .transition(slide)
                case .importStep:
                    ImportScreen(
                        copy: copy,
                        dests: dests,
                        onFilePicked: { data, filename in
                            pickedFile = PickedFile(data: data, filename: filename)
                        },
                        onSkip: onSkipped,
                        onContinue: { advance(.evidence) }
                    )
                    .transition(slide)
                case .evidence:
                    EvidenceScreen(copy: copy, region: region, onSeeNumber: onFinished)
                        .transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .fullScreenCover(item: $pickedFile) { file in
            ImportFlowView(
                fileData: file.data,
                filename: file.filename,
                onAnalyzed: {
                    // Land back on the import screen (now in its "add
                    // another / see my number" state) so multiple months can
                    // be uploaded before the Reveal.
                    pickedFile = nil
                },
                onCancel: {
                    pickedFile = nil
                }
            )
        }
    }

    private func advance(_ next: Step) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { step = next }
    }

    // MARK: - Progress dots + region confirm

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { index in
                    Capsule()
                        .fill(dotColor(index))
                        .frame(width: index == step.dot ? 24 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.3), value: step.dot)
                }
            }
            Spacer()
        }
    }

    private func dotColor(_ index: Int) -> Color {
        if index == step.dot { return Theme.accent }
        if index < step.dot { return Theme.accent.opacity(0.5) }
        return Color.white.opacity(0.15)
    }
}

// MARK: - Screen 1: invoke emotion

private struct EmotionScreen: View {
    let copy: RegionCopy
    var onContinue: () -> Void

    @State private var showBilled = false
    @State private var showShould = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            receipt
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)

            Text(copy.s1Headline)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .lineSpacing(2)
                .padding(.top, 36)

            Text(copy.s1Subhead)
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(4)
                .padding(.top, 16)

            Spacer(minLength: 24)

            PrimaryButton(title: copy.s1Button, action: onContinue)
        }
        .onAppear {
            // Billed total glows in red, then the mid-market line slides in.
            withAnimation(.easeOut(duration: 0.6).delay(0.7)) { showBilled = true }
            withAnimation(.easeOut(duration: 0.45).delay(1.5)) { showShould = true }
        }
    }

    private var dashedDivider: some View {
        LineShape()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(Color.white.opacity(0.15))
            .frame(height: 1)
    }

    private var receipt: some View {
        VStack(spacing: 0) {
            Text(copy.receiptMerchant)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .kerning(2.2)
                .foregroundStyle(Theme.cream.opacity(0.8))
                .frame(maxWidth: .infinity)

            dashedDivider
                .padding(.vertical, 12)

            VStack(spacing: 5) {
                ForEach(copy.receiptLines, id: \.label) { line in
                    HStack {
                        Text(line.label)
                        Spacer()
                        Text(line.amount)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                }
            }

            dashedDivider
                .padding(.vertical, 12)

            HStack(alignment: .firstTextBaseline) {
                Text("TOTAL")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.cream)
                Spacer()
                Text(copy.receiptBilled)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.loss)
                    .shadow(color: Theme.loss.opacity(0.6), radius: 9)
                    .opacity(showBilled ? 1 : 0)
            }

            HStack {
                Spacer()
                Text(copy.receiptShould)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.good)
            }
            .padding(.top, 6)
            .opacity(showShould ? 1 : 0)
            .offset(x: showShould ? 0 : -36)
        }
        .padding(20)
        .surfaceCard()
        .rotationEffect(.degrees(-1.5))
    }
}

// MARK: - Screen 2: demonstrate benefits

private struct BenefitsScreen: View {
    let copy: RegionCopy
    var onContinue: () -> Void

    @State private var appeared = false

    private let icons = ["magnifyingglass", "bell.fill", "bolt.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(copy.s2Headline)
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .lineSpacing(2)

            VStack(spacing: 16) {
                ForEach(Array(copy.s2Benefits.enumerated()), id: \.offset) { index, benefit in
                    benefitCard(icon: icons[index % icons.count], benefit: benefit)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 24)
                        .animation(
                            .easeOut(duration: 0.45).delay(0.25 + Double(index) * 0.18),
                            value: appeared
                        )
                }
            }
            .padding(.top, 32)

            Spacer(minLength: 24)

            PrimaryButton(title: copy.s2Button, action: onContinue)
        }
        .onAppear { appeared = true }
    }

    private func benefitCard(icon: String, benefit: Benefit) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accent.opacity(0.15), in: Circle())

            (
                Text(benefit.bold)
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.cream)
                + Text(benefit.rest)
                    .foregroundStyle(Theme.muted)
            )
            .font(.system(size: 13.5))
            .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .surfaceCard()
    }
}

// MARK: - Screen 3a: two quick questions

private struct QuestionsScreen: View {
    let copy: RegionCopy
    let region: RegionConfig
    @Binding var freq: TripFreqBucket?
    @Binding var dests: Set<String>
    var onContinue: () -> Void

    // Persisted here (not just held in local @State) so Home/Trips/Profile
    // can read the answers immediately, and Profile can edit them later.
    @AppStorage("profile.name") private var storedName: String = ""
    @AppStorage("profile.tripFreq") private var storedTripFreq: String = ""
    @AppStorage("profile.destinations") private var storedDestinations: String = ""
    // Home currency/country is the ONE calculation-critical answer — it decides
    // what counts as "foreign", so every number downstream depends on it.
    // Pre-set to Hong Kong so it's confirm-or-correct, never a blocker.
    @AppStorage("profile.homeCountry") private var storedHomeCountry: String = HomeRegion.defaultCountry
    @AppStorage("profile.homeCurrency") private var storedHomeCurrency: String = RateProvider.defaultHomeCurrency

    @FocusState private var nameFocused: Bool

    /// Liquid-glass name field — the whole capsule is one tap target
    /// (tapping anywhere focuses the field), with the accent stroke, person
    /// glyph, and a confirming checkmark all animating on focus/typing.
    private var nameField: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(nameFocused ? Theme.accent : Theme.muted)
                .scaleEffect(nameFocused ? 1.08 : 1)

            TextField("Your first name (optional)", text: $storedName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textContentType(.givenName)
                .submitLabel(.done)
                .focused($nameFocused)
                .font(.app(14.5, weight: .semibold))
                .foregroundStyle(Theme.cream)
                .tint(Theme.accent)

            if !storedName.trimmingCharacters(in: .whitespaces).isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.good)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { nameFocused = true }
        .glass(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    nameFocused ? Theme.accent.opacity(0.55) : Color.white.opacity(0.1),
                    lineWidth: 1
                )
        )
        .shadow(color: Theme.accent.opacity(nameFocused ? 0.22 : 0), radius: 14, y: 6)
        .scaleEffect(nameFocused ? 1.015 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: nameFocused)
        .animation(
            .spring(response: 0.32, dampingFraction: 0.7),
            value: storedName.trimmingCharacters(in: .whitespaces).isEmpty
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick — a few questions.")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Theme.cream)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Q0 — name (optional; greetings degrade gracefully
                    // without it).
                    Text("What should we call you?")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.cream.opacity(0.9))
                        .padding(.top, 28)

                    nameField
                        .padding(.top, 12)

                    // Q1 — home region (the calc-critical one).
                    Text("Where do you call home?")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.cream.opacity(0.9))
                        .padding(.top, 32)

                    FlowLayout(spacing: 8) {
                        ForEach(HomeRegion.options) { option in
                            Chip(
                                label: "\(Derive.flag(option.country)) \(option.name)",
                                isOn: storedHomeCountry == option.country
                            ) {
                                storedHomeCountry = option.country
                                storedHomeCurrency = option.currency
                            }
                        }
                    }
                    .padding(.top, 12)

                    Text("All your losses are measured in \(storedHomeCurrency).")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 8)

                    // Q2 — trip frequency.
                    Text("How many trips outside \(HomeRegion.name(forCountry: storedHomeCountry)) in the last 12 months?")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.cream.opacity(0.9))
                        .padding(.top, 32)

                    DetentSlider(selection: $freq)
                        .padding(.top, 20)

                    // Q3 — destinations.
                    Text(copy.s3Q2)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.cream.opacity(0.9))
                        .padding(.top, 32)

                    CountrySelectField(selection: $dests)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                }
                // Selected chips spring to 1.04x — give their stroke 4pt of
                // clip room on each side instead of cutting it flush.
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, -4)

            PrimaryButton(
                title: "Continue",
                isDisabled: freq == nil || dests.isEmpty,
                action: {
                    storedTripFreq = freq?.rawValue ?? ""
                    storedDestinations = dests.joined(separator: ",")
                    onContinue()
                }
            )
            .padding(.top, 8)
        }
    }
}

// MARK: - Screen 3b: statement import

private struct ImportScreen: View {
    let copy: RegionCopy
    var dests: Set<String> = []
    var onFilePicked: (Data, String) -> Void
    var onSkip: () -> Void
    /// Advances to the evidence scan once the user is done adding statements.
    var onContinue: () -> Void

    @ObservedObject private var appStore = AppStore.shared

    /// True once at least one statement has been imported — the screen flips
    /// into "add another / see my number" mode so multiple months can be
    /// uploaded before the Reveal.
    private var hasImports: Bool {
        !appStore.transactions.isEmpty
    }

    /// Best-effort waitlist-country bucket from the first chosen destination
    /// — a tiny prefill so the waitlist form isn't blank when we already
    /// have a strong hint where the user travels.
    private var prefillCountry: String? {
        guard let first = dests.sorted().first, let info = Derive.destinationInfo(first) else { return nil }
        switch info.country {
        case "HK": return "HK"
        case "US": return "US"
        case "GB": return "UK"
        case "NL", "ES", "FR", "IT", "GR", "PT": return "EU"
        default: return "Other"
        }
    }

    @State private var isImporterPresented = false
    @State private var showWaitlistSheet = false
    @State private var showSupportSheet = false
    @State private var pickError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if hasImports {
                        importedSummaryCard
                    }

                    uploadCard

                    if let pickError {
                        Text(pickError)
                            .font(.app(11.5, weight: .semibold))
                            .foregroundStyle(Theme.loss)
                    }

                    comingSoonCard
                }
                .padding(.bottom, 8)
            }

            if hasImports {
                // Statements are in — the estimate skip no longer applies;
                // the exit is seeing the real number.
                PrimaryButton(title: "See my number", action: onContinue)
                    .padding(.top, 16)
            } else {
                Button(action: onSkip) {
                    Text(copy.s3bSkip)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .underline()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.commaSeparatedText, .plainText, .pdf],
            allowsMultipleSelection: false
        ) { result in
            handlePick(result)
        }
        .sheet(isPresented: $showWaitlistSheet) {
            WaitlistSheet(submitter: WaitlistService(), prefillCountry: prefillCountry)
        }
        .sheet(isPresented: $showSupportSheet) {
            SupportPlaceholderSheet()
        }
    }

    /// Shown once a statement is in — running totals plus the nudge that
    /// more months make the number more complete.
    private var importedSummaryCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.good)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(appStore.transactions.count) charge\(appStore.transactions.count == 1 ? "" : "s") imported · \(appStore.cards.count) card\(appStore.cards.count == 1 ? "" : "s")")
                    .font(.app(13, weight: .bold))
                    .foregroundStyle(Theme.cream)
                Text("Add more months for the full picture — duplicates are skipped, and trips stitch across statements automatically.")
                    .font(.app(11.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .surfaceCard(cornerRadius: 18)
    }

    private var uploadCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hasImports ? "Add another statement" : copy.s3bHeadline)
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .lineSpacing(2)

            Text(hasImports
                ? "Another month, another card — every statement folds into the same report."
                : copy.s3bSubhead)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 14)

            Text("CSV recommended · text-PDF supported · processed on this device")
                .font(.app(11, weight: .semibold))
                .foregroundStyle(Theme.muted.opacity(0.9))
                .lineSpacing(3)
                .padding(.top, 14)

            PrimaryButton(
                title: hasImports ? "Choose another statement" : copy.s3bButton,
                leadingIcon: "lock.fill",
                trailingIcon: nil,
                action: { isImporterPresented = true }
            )
            .padding(.top, 22)
        }
        .padding(20)
        .surfaceCard()
    }

    private var comingSoonCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Automatic bank connection")
                    .font(.app(14, weight: .bold))
                    .foregroundStyle(Theme.cream)
                Spacer()
                Text("COMING SOON")
                    .font(.app(9, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }

            Text("Tell us your bank — demand decides which countries we build first.")
                .font(.app(12))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 10)

            HStack(spacing: 16) {
                Button {
                    showWaitlistSheet = true
                } label: {
                    Text("Join the free waitlist")
                        .font(.app(12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressStyle(scale: 0.96))

                Spacer()

                Button {
                    showSupportSheet = true
                } label: {
                    Text("Support Skimmed")
                        .font(.app(11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(PressStyle(scale: 0.96))
            }
            .padding(.top, 16)
        }
        .padding(18)
        .glass(cornerRadius: 20)
    }

    /// Reads the picked file into memory (security-scoped access, released
    /// immediately after) and hands the raw bytes up — the temp URL itself
    /// is never copied or retained.
    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pickError = nil
                onFilePicked(data, url.lastPathComponent)
            } catch {
                pickError = "Couldn't read that file — try another one."
            }
        case .failure:
            pickError = "Couldn't read that file — try another one."
        }
    }
}

// MARK: - Waitlist (free, never coupled to payment)

/// Submission interface for the free automatic-connection waitlist. B7 wires
/// the real `WaitlistService` (configurable endpoint, local-persist mock)
/// conforming to this; the sheet itself doesn't change.
protocol WaitlistSubmitting {
    func submit(email: String, country: String, bank: String, accountType: AccountType, note: String?) async throws
}

/// Not `private` — B7's Profile "Waitlist" row reopens this sheet (prefilled
/// from the cached entry) to let the user edit/resubmit or leave.
struct WaitlistSheet: View {
    let submitter: WaitlistSubmitting
    var prefillCountry: String? = nil
    /// When set, the sheet opens in "manage" mode: fields prefilled from the
    /// user's existing submission and a destructive "Leave waitlist" action
    /// is offered alongside resubmission. Nil for the first-time join flow.
    var prefillEntry: WaitlistEntry? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var country: String? = nil
    @State private var bank = ""
    @State private var accountType: AccountType = .credit
    @State private var note = ""
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String? = nil
    @State private var showLeaveConfirm = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let countries = ["HK", "US", "UK", "EU", "Other"]

    private var isValid: Bool {
        isValidEmail(email) && country != nil && !bank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isValidEmail(_ s: String) -> Bool {
        s.range(of: #"^\S+@\S+\.\S+$"#, options: .regularExpression) != nil
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(spacing: 0) {
                header
                if submitted {
                    successState
                } else {
                    formState
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .onAppear {
            if let prefillEntry {
                email = prefillEntry.email
                country = prefillEntry.country
                bank = prefillEntry.bank
                accountType = prefillEntry.accountType
                note = prefillEntry.note
            } else if country == nil {
                country = prefillCountry
            }
        }
        .confirmationDialog(
            "Leave the waitlist?",
            isPresented: $showLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave waitlist", role: .destructive) {
                WaitlistService.clearSubmission()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop being notified about automatic connections for \(bank.isEmpty ? "your bank" : bank).")
        }
    }

    private var header: some View {
        HStack {
            Text(prefillEntry != nil ? "Manage waitlist" : "Join the waitlist")
                .font(.app(18, weight: .heavy))
                .foregroundStyle(Theme.cream)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.cream)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.06), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(PressStyle(scale: 0.9))
        }
        .padding(.bottom, 16)
    }

    private var formState: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Automatic bank connection is coming. Tell us where and which bank, and we'll notify you the moment it's live — free, no payment needed.")
                    .font(.app(12.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)

                field(label: "Email") {
                    TextField("you@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("COUNTRY")
                        .font(.app(10, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(Theme.muted)
                    FlowLayout(spacing: 8) {
                        ForEach(countries, id: \.self) { c in
                            Chip(label: c, isOn: country == c) { country = c }
                        }
                    }
                }

                field(label: "Bank") {
                    TextField("e.g. HSBC", text: $bank)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("ACCOUNT TYPE")
                        .font(.app(10, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Chip(label: "Credit", isOn: accountType == .credit) { accountType = .credit }
                        Chip(label: "Debit", isOn: accountType == .debit) { accountType = .debit }
                    }
                }

                field(label: "Note (optional)") {
                    TextField("Anything else we should know?", text: $note)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.good)
                    Text("We only use this to notify you when your bank connects. Joining is free — never linked to any purchase. Never shared, never sold.")
                        .font(.app(11))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.app(11.5))
                        .foregroundStyle(Theme.loss)
                }

                PrimaryButton(
                    title: isSubmitting ? "Joining…" : (prefillEntry != nil ? "Update" : "Join the waitlist"),
                    trailingIcon: nil,
                    isDisabled: !isValid || isSubmitting,
                    action: submit
                )
                .padding(.top, 4)

                if prefillEntry != nil {
                    Button(role: .destructive) {
                        showLeaveConfirm = true
                    } label: {
                        Text("Leave waitlist")
                            .font(.app(12.5, weight: .semibold))
                            .foregroundStyle(Theme.loss)
                    }
                    .buttonStyle(PressStyle(scale: 0.96))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.app(10, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.muted)
            content()
                .font(.app(14))
                .foregroundStyle(Theme.cream)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    private var successState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.good)
            Text("You're on the list.")
                .font(.app(18, weight: .heavy))
                .foregroundStyle(Theme.cream)
            Text("We'll email you the moment automatic connections open in your country.")
                .font(.app(12.5))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer()
            PrimaryButton(title: "Done", action: { dismiss() })
        }
    }

    private func submit() {
        errorMessage = nil
        isSubmitting = true
        Task {
            do {
                try await submitter.submit(
                    email: email, country: country ?? "", bank: bank,
                    accountType: accountType, note: note.isEmpty ? nil : note
                )
                isSubmitting = false
                let anim: Animation = reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85)
                withAnimation(anim) { submitted = true }
            } catch {
                isSubmitting = false
                errorMessage = "Something went wrong — try again."
            }
        }
    }
}

// MARK: - "Support Skimmed" — real founding-supporter purchase (B5)

/// Separate and clearly optional from the automatic-connection waitlist —
/// this is a purchase surface, the waitlist is free. Benefits are kept
/// honestly limited to what's actually delivered: a founding-supporter badge
/// (Profile) and a priority-beta-access note — no untrackable promises.
private struct SupportPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var purchasing = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "heart.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)
                Text("Support Skimmed")
                    .font(.app(18, weight: .heavy))
                    .foregroundStyle(Theme.cream)
                Text("Skimmed is built by a tiny, independent team. Founding supporters help keep it that way.")
                    .font(.app(13))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 10) {
                    benefitRow("Founding supporter badge on your Profile")
                    benefitRow("Priority access to new features in beta")
                }
                .padding(20)
                .surfaceCard(cornerRadius: 18)
                .padding(.horizontal, 24)

                Group {
                    if entitlements.isSupporter {
                        Text("You're already a founding supporter — thank you.")
                            .font(.app(12.5, weight: .semibold))
                            .foregroundStyle(Theme.good)
                    } else if let product = entitlements.supporterProduct {
                        VStack(spacing: 10) {
                            PrimaryButton(
                                title: purchasing ? "Processing…" : "Become a founding supporter — \(product.displayPrice)",
                                trailingIcon: nil,
                                isDisabled: purchasing
                            ) {
                                Task {
                                    purchasing = true
                                    errorMessage = nil
                                    do {
                                        try await entitlements.purchase(product)
                                    } catch {
                                        errorMessage = "Something went wrong — please try again."
                                    }
                                    purchasing = false
                                }
                            }
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.app(11))
                                    .foregroundStyle(Theme.loss)
                            }
                        }
                        .padding(.horizontal, 24)
                    } else {
                        Text("Purchases unavailable right now.")
                            .font(.app(12))
                            .foregroundStyle(Theme.muted)
                    }
                }

                Spacer()

                PrimaryButton(title: entitlements.isSupporter ? "Done" : "Not now", action: { dismiss() })
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .task { await entitlements.loadProducts() }
    }

    private func benefitRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.good)
            Text(text)
                .font(.app(12.5))
                .foregroundStyle(Theme.cream.opacity(0.9))
        }
    }
}

// MARK: - Screen 4: scientific evidence + statement scan

private struct EvidenceScreen: View {
    let copy: RegionCopy
    let region: RegionConfig
    var onSeeNumber: () -> Void

    @State private var found = 0
    @State private var scanDone = false

    /// Placeholder until `.task` derives the real import's numbers — this
    /// screen is only reachable after at least one statement is in.
    @State private var target = 0
    @State private var months = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(copy.s4Headline)
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Theme.cream)

            Text(emphasized(region.evidenceCitationText))
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .lineSpacing(4)
                .padding(.top, 20)

            proofRow
                .padding(.top, 24)

            Spacer(minLength: 24)

            scanCard

            PrimaryButton(title: copy.s4Button, isDisabled: !scanDone, action: onSeeNumber)
                .padding(.top, 20)
        }
        .task {
            // Count up to the real foreign-charge count over the real
            // statement span.
            let txs = AppStore.shared.transactions
            target = txs.filter(\.isForeign).count
            let dates = txs.map(\.txDate)
            if let lo = dates.min(), let hi = dates.max() {
                let days = Derive.daysBetween(lo, hi)
                months = max(1, Int((Double(days) / 30.4375).rounded(.up)))
            } else {
                months = 1
            }

            // Statement scan: count up 0 → target over ~3.2s.
            let duration = 3.2
            let start = Date()
            let total = max(0, target)
            while !Task.isCancelled {
                let progress = min(1, Date().timeIntervalSince(start) / duration)
                found = Int((progress * Double(total)).rounded())
                if progress >= 1 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            found = total
            scanDone = true
        }
    }

    private var proofRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
            (
                Text(copy.s4ProofRow[0] + " · ")
                + Text(copy.s4ProofRow[1])
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.cream.opacity(0.85))
                + Text(" · " + copy.s4ProofRow[2])
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.muted)
            .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .surfaceCard()
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(copy.scanLine(found: found, months: months))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.cream.opacity(0.85))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accentHot],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(found) / CGFloat(max(1, target)))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glass(cornerRadius: 16)
    }
}
