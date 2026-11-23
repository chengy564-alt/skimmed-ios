import SwiftUI

/// The statement-import pipeline, presented as a `fullScreenCover` from
/// `OnboardingView`'s `ImportScreen` once a file is picked. A small
/// step-state machine in Skimmed's own visual language: parse → (map
/// columns if needed) → confirm bank → match/create card → preview → analyze
/// → hand back to onboarding (which advances to `EvidenceScreen`).
///
/// Parsing/analysis run inside `.task`'s async context rather than a
/// `Task.detached` — ImportCore's parse/analyze calls are pure, in-memory,
/// and complete in milliseconds even on realistic statements (see B1/B2/B3's
/// test timings), so detaching would only add Sendable friction for no real
/// responsiveness win; the spinner states keep the UI honest either way.
struct ImportFlowView: View {
    let fileData: Data
    let filename: String
    /// When set, the committed import is also attached to this planned trip
    /// (the new-trip audit flow reuses this pipeline end to end).
    var tripID: UUID? = nil
    var onAnalyzed: () -> Void
    var onCancel: () -> Void

    private enum Step: Equatable {
        case parsing, mapping, unreadable, empty, bankConfirm, cardMatch, cardProduct, preview, analyzing
    }

    @State private var step: Step = .parsing
    @State private var statement: ParsedStatement? = nil
    @State private var mappingHeaders: [String] = []
    @State private var mappingSampleRows: [[String]] = []
    @State private var bankGuess: BankGuess? = nil
    @State private var confirmedBank: String = ""
    /// The exact catalogue institution the user confirmed (nil = unknown
    /// bank). Carried explicitly so a cross-market pick like "HSBC UK" can
    /// never fuzzy-match back to the home market's HSBC.
    @State private var confirmedInstitution: Institution? = nil
    @State private var resolvedCard: ImportedCard? = nil
    @State private var mappingConfirmInFlight = false

    @AppStorage("profile.homeCountry") private var homeCountry: String = HomeRegion.defaultCountry
    @AppStorage("profile.homeCurrency") private var homeCurrency: String = RateProvider.defaultHomeCurrency

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stepTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }

    private var springAnim: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(spacing: 0) {
                topBar
                ZStack {
                    switch step {
                    case .parsing:
                        parsingView
                            .transition(stepTransition)
                    case .mapping:
                        MappingStep(
                            headers: mappingHeaders,
                            sampleRows: mappingSampleRows,
                            isSubmitting: mappingConfirmInFlight,
                            onConfirm: handleMappingConfirm,
                            onCancel: onCancel
                        )
                        .transition(stepTransition)
                    case .unreadable:
                        ImportErrorStep(
                            title: "We couldn't read that statement",
                            message: "We couldn't read this statement reliably. Try exporting a CSV from your bank instead.",
                            onTryAnother: onCancel,
                            onClose: onCancel
                        )
                        .transition(stepTransition)
                    case .empty:
                        ImportErrorStep(
                            title: "Nothing to import",
                            message: "No transactions found in that file.",
                            onTryAnother: onCancel,
                            onClose: onCancel
                        )
                        .transition(stepTransition)
                    case .bankConfirm:
                        BankConfirmStep(guess: bankGuess) { name, institution in
                            handleBankConfirmed(name, institution)
                        }
                        .transition(stepTransition)
                    case .cardMatch:
                        if let statement {
                            CardMatchStep(
                                proposal: CardMatcher.proposals(
                                    bank: confirmedBank,
                                    last4: statement.accountLast4,
                                    existing: AppStore.shared.cards
                                ),
                                detectedBank: confirmedBank,
                                last4: statement.accountLast4,
                                onResolved: handleCardResolved
                            )
                            .transition(stepTransition)
                        }
                    case .cardProduct:
                        if let resolvedCard, let confirmedInstitution {
                            CardProductStep(
                                card: resolvedCard,
                                institution: confirmedInstitution,
                                onDone: { withAnimation(springAnim) { step = .preview } }
                            )
                            .transition(stepTransition)
                        }
                    case .preview:
                        if let statement, let resolvedCard {
                            PreviewStep(
                                statement: statement,
                                bank: confirmedBank,
                                card: resolvedCard,
                                onAdjustMapping: isCSVSource ? { reopenMapping() } : nil,
                                onContinue: { edited in
                                    self.statement = edited
                                    withAnimation(springAnim) { step = .analyzing }
                                }
                            )
                            .transition(stepTransition)
                        }
                    case .analyzing:
                        if let statement, let resolvedCard {
                            AnalyzeStep(
                                statement: statement,
                                card: resolvedCard,
                                tripID: tripID,
                                homeCountry: homeCountry,
                                homeCurrency: AppStore.shared.importedDataHomeCurrency ?? homeCurrency,
                                onFinished: { _ in onAnalyzed() }
                            )
                            .transition(stepTransition)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .task { await runParse(mapping: nil) }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            if step != .analyzing {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.cream)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(PressStyle(scale: 0.9))
            }
        }
        .padding(.bottom, 12)
    }

    private var parsingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text("Reading your statement…")
                .font(.app(13, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step transitions

    private func runParse(mapping: ColumnMapping?) async {
        step = .parsing
        do {
            let parsed: ParsedStatement
            if let mapping {
                parsed = try CSVImporter.parse(data: fileData, mapping: mapping)
            } else {
                // Content-sniffed, not filename-trusted — a mis-extensioned
                // export (e.g. a PDF saved as "statement.txt") still lands
                // on the right parser. See StatementImporter.parse.
                parsed = try StatementImporter.parse(data: fileData, filename: filename)
            }
            statement = parsed
            bankGuess = BankDetector.detect(filename: filename, statement: parsed, rawText: nil)
            withAnimation(springAnim) { step = .bankConfirm }
        } catch let error as ImportError {
            switch error {
            case .needsMapping(let headers, let sampleRows):
                // A remembered template (keyed by header signature — the bank
                // isn't confirmed yet at this point in the flow) lets a
                // repeat export from the same unrecognised layout skip
                // MappingStep entirely. Only fall back to asking again if no
                // template exists, or if replaying it doesn't actually work.
                if let template = MappingTemplateStore().load(bank: nil, headers: headers),
                   let reparsed = try? CSVImporter.parse(data: fileData, mapping: template),
                   !reparsed.transactions.isEmpty {
                    statement = reparsed
                    bankGuess = BankDetector.detect(filename: filename, statement: reparsed, rawText: nil)
                    withAnimation(springAnim) { step = .bankConfirm }
                } else {
                    mappingHeaders = headers
                    mappingSampleRows = sampleRows
                    withAnimation(springAnim) { step = .mapping }
                }
            case .unreadable:
                withAnimation(springAnim) { step = .unreadable }
            case .empty:
                withAnimation(springAnim) { step = .empty }
            }
        } catch {
            withAnimation(springAnim) { step = .unreadable }
        }
    }

    private func handleMappingConfirm(_ mapping: ColumnMapping) {
        let headersAtMappingTime = mappingHeaders
        mappingConfirmInFlight = true
        Task {
            await runParse(mapping: mapping)
            // Only remember this mapping once it has actually proven itself
            // against the real file — an unconditional save would enshrine a
            // broken template the moment the user first tries one.
            if step == .bankConfirm {
                try? MappingTemplateStore().save(mapping, bank: nil, headers: headersAtMappingTime)
            }
            mappingConfirmInFlight = false
        }
    }

    private func handleBankConfirmed(_ bank: String, _ institution: Institution?) {
        confirmedBank = bank
        // Picker rows pass their exact institution; detector confirmations
        // and free-text entries resolve by name (exact cross-market name
        // first, then home-market brand/alias).
        confirmedInstitution = institution ?? CardCatalog.institution(
            named: bank,
            market: UserDefaults.standard.string(forKey: "profile.homeCountry") ?? HomeRegion.defaultCountry
        )
        withAnimation(springAnim) { step = .cardMatch }
    }

    /// True when the picked file is not a PDF — mapping only exists for
    /// tabular sources, so only they get the "adjust mapping" escape hatch.
    private var isCSVSource: Bool {
        !fileData.starts(with: Array("%PDF".utf8))
    }

    /// Reopens MappingStep from the preview ("columns look wrong"), feeding
    /// it the file's real headers again.
    private func reopenMapping() {
        guard let (headers, sampleRows) = try? CSVImporter.headers(data: fileData) else { return }
        mappingHeaders = headers
        mappingSampleRows = sampleRows
        withAnimation(springAnim) { step = .mapping }
    }

    private func handleCardResolved(_ card: ImportedCard) {
        resolvedCard = card
        // Re-importing into an existing card whose bank differs from this
        // statement's confirmed bank: resolve from the card's own bank name.
        if confirmedInstitution == nil || card.bank != confirmedBank {
            let market = UserDefaults.standard.string(forKey: "profile.homeCountry") ?? HomeRegion.defaultCountry
            confirmedInstitution = CardCatalog.institution(named: card.bank, market: market)
                ?? CardCatalog.institution(named: card.bank, market: "INTL")
        }
        // Unknown bank → nothing to pick from; the flow proceeds bank-only
        // (the honest degradation path).
        withAnimation(springAnim) { step = confirmedInstitution == nil ? .preview : .cardProduct }
    }
}

// MARK: - Mapping step (manual column assignment for .needsMapping)

private struct MappingStep: View {
    let headers: [String]
    let sampleRows: [[String]]
    let isSubmitting: Bool
    var onConfirm: (ColumnMapping) -> Void
    var onCancel: () -> Void

    @State private var mapping = ColumnMapping()

    private struct Role {
        let key: WritableKeyPath<ColumnMapping, Int?>
        let label: String
        let required: Bool
    }

    private let roles: [Role] = [
        Role(key: \.date, label: "Date", required: true),
        Role(key: \.description, label: "Description", required: true),
        Role(key: \.amount, label: "Amount (signed)", required: false),
        Role(key: \.debit, label: "Debit / money out", required: false),
        Role(key: \.credit, label: "Credit / money in", required: false),
        Role(key: \.currency, label: "Currency", required: false),
        Role(key: \.originalAmount, label: "Original amount", required: false),
        Role(key: \.originalCurrency, label: "Original currency", required: false),
        Role(key: \.cardLast4, label: "Card last 4", required: false),
    ]

    private var isValid: Bool {
        mapping.date != nil && mapping.description != nil
            && (mapping.amount != nil || mapping.debit != nil || mapping.credit != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Match your columns")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.cream)

            Text("We couldn't auto-detect this bank's layout. Tell us which column is which — just once, we'll remember it next time.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(roles, id: \.label) { role in
                        roleRow(role)
                    }
                    previewCard
                }
                .padding(.top, 20)
            }

            PrimaryButton(title: "Confirm mapping", isDisabled: !isValid || isSubmitting) {
                onConfirm(mapping)
            }
            .padding(.top, 16)
        }
    }

    private func roleRow(_ role: Role) -> some View {
        HStack {
            Text(role.label + (role.required ? " *" : ""))
                .font(.app(12.5, weight: .semibold))
                .foregroundStyle(Theme.cream)
            Spacer()
            Menu {
                Button("None") { mapping[keyPath: role.key] = nil }
                ForEach(headers.indices, id: \.self) { idx in
                    Button(headers[idx]) { mapping[keyPath: role.key] = idx }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(mapping[keyPath: role.key].flatMap { headers.indices.contains($0) ? headers[$0] : nil } ?? "None")
                        .font(.app(12, weight: .semibold))
                        .foregroundStyle(mapping[keyPath: role.key] != nil ? Theme.accent : Theme.muted)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            }
        }
        .padding(.vertical, 4)
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW")
                .font(.app(10, weight: .semibold))
                .kerning(1.2)
                .foregroundStyle(Theme.muted)
            ForEach(sampleRows.indices.prefix(5), id: \.self) { i in
                let row = sampleRows[i]
                HStack {
                    Text(cell(row, mapping.date))
                        .frame(width: 70, alignment: .leading)
                    Text(cell(row, mapping.description))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    Text(cell(row, mapping.amount ?? mapping.debit ?? mapping.credit))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.muted)
            }
        }
        .padding(14)
        .surfaceCard(cornerRadius: 16)
    }

    private func cell(_ row: [String], _ idx: Int?) -> String {
        guard let idx, idx < row.count else { return "—" }
        return row[idx]
    }
}

// MARK: - Honest error states (.unreadable / .empty)

private struct ImportErrorStep: View {
    let title: String
    let message: String
    var onTryAnother: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.loss)

            Text(title)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 10)

            Spacer()

            PrimaryButton(title: "Try another file", trailingIcon: nil, action: onTryAnother)

            Button(action: onClose) {
                Text("Close")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .underline()
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
    }
}

// MARK: - Bank confirmation / search

private struct BankConfirmStep: View {
    let guess: BankGuess?
    var onConfirm: (String, Institution?) -> Void

    @State private var showSelector = false
    @State private var search = ""
    @State private var countryFilter: String? = nil
    @State private var enteringOther = false
    @State private var otherBankName = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func toggleAnim(response: Double) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: response, dampingFraction: 0.85)
    }

    /// Markets shown as filter chips: the user's home market first, then the
    /// rest of the catalogue. "INTL" (Wise/Revolut) is folded into every
    /// market's results rather than shown as its own chip.
    private var marketChips: [String] {
        let home = UserDefaults.standard.string(forKey: "profile.homeCountry") ?? HomeRegion.defaultCountry
        var markets = CardCatalog.markets.filter { $0 != "INTL" }
        if let i = markets.firstIndex(of: home) { markets.remove(at: i); markets.insert(home, at: 0) }
        return markets
    }

    private var isConfident: Bool { (guess?.confidence ?? 0) >= 0.8 }

    /// Country-filtered, popular-first catalogue search; international
    /// issuers (Wise, Revolut) always included.
    private var filteredInstitutions: [Institution] {
        let market = countryFilter ?? marketChips.first ?? "US"
        return CardCatalog.searchInstitutions(market: market, query: search)
            + CardCatalog.searchInstitutions(market: "INTL", query: search)
    }

    var body: some View {
        Group {
            if !showSelector, isConfident, let guess {
                confidentCard(guess)
            } else {
                selector
            }
        }
        .onAppear {
            if !isConfident { showSelector = true }
        }
    }

    private func confidentCard(_ guess: BankGuess) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Whose statement is this?")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.cream)

            HStack(spacing: 14) {
                BankMark(bank: guess.name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("We think this statement is from")
                        .font(.app(11.5))
                        .foregroundStyle(Theme.muted)
                    Text(guess.name)
                        .font(.app(17, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                }
                Spacer()
            }
            .padding(18)
            .surfaceCard(cornerRadius: 20)
            .padding(.top, 28)

            Spacer(minLength: 24)

            PrimaryButton(title: "Yes, that's right", action: { onConfirm(guess.name, nil) })

            Button {
                withAnimation(toggleAnim(response: 0.4)) { showSelector = true }
            } label: {
                Text("It's a different bank")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .underline()
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
    }

    private var selector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Which bank is this?")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.cream)

            searchField
                .padding(.top, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(marketChips, id: \.self) { c in
                        Chip(label: Derive.countryName(c), isOn: (countryFilter ?? marketChips.first) == c) {
                            countryFilter = c
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -4)
            .padding(.top, 12)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(filteredInstitutions) { inst in
                        bankRow(inst.name) { onConfirm(inst.name, inst) }
                    }
                    otherBankRow
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            TextField("Search banks", text: $search)
                .font(.app(13))
                .foregroundStyle(Theme.cream)
                .textInputAutocapitalization(.words)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func bankRow(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                BankMark(bank: name, size: 30)
                Text(name)
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }

    private var otherBankRow: some View {
        Group {
            if enteringOther {
                HStack(spacing: 8) {
                    TextField("Bank name", text: $otherBankName)
                        .font(.app(13))
                        .foregroundStyle(Theme.cream)
                    Button("Use this") {
                        let trimmed = otherBankName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onConfirm(trimmed, nil)
                    }
                    .font(.app(12, weight: .bold))
                    .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
            } else {
                bankRow("Other bank") {
                    withAnimation(toggleAnim(response: 0.35)) { enteringOther = true }
                }
            }
        }
    }
}

// MARK: - Card match / create

private struct CardMatchStep: View {
    let proposal: MatchProposal
    let detectedBank: String
    let last4: String?
    var onResolved: (ImportedCard) -> Void

    @State private var creatingNew: Bool
    @State private var bankName: String
    @State private var nickname: String
    @State private var accountType: AccountType = .credit

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var toggleAnim: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.85)
    }

    init(proposal: MatchProposal, detectedBank: String, last4: String?, onResolved: @escaping (ImportedCard) -> Void) {
        self.proposal = proposal
        self.detectedBank = detectedBank
        self.last4 = last4
        self.onResolved = onResolved
        if case .createNew = proposal {
            _creatingNew = State(initialValue: true)
        } else {
            _creatingNew = State(initialValue: false)
        }
        _bankName = State(initialValue: detectedBank)
        _nickname = State(initialValue: "\(detectedBank) card")
    }

    private var canConfirmCreate: Bool {
        guard last4 == nil else { return true }
        return !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Which card is this?")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.cream)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if creatingNew {
                        createForm
                    } else {
                        switch proposal {
                        case .exact(let card):
                            confirmCard(card, subtitle: "This matches a card you've already imported.")
                        case .suggest(let card):
                            confirmCard(card, subtitle: "Is this the card?")
                        case .choose(let cards):
                            ForEach(cards) { card in
                                selectRow(card)
                            }
                            addNewRow
                        case .createNew:
                            EmptyView()
                        }
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 12)
            }

            if creatingNew {
                PrimaryButton(title: "Confirm card", isDisabled: !canConfirmCreate) {
                    let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    onResolved(ImportedCard(
                        bank: bankName,
                        nickname: trimmedNickname.isEmpty ? "\(bankName) card" : trimmedNickname,
                        last4: last4,
                        accountType: accountType
                    ))
                }
            }
        }
    }

    private func confirmCard(_ card: ImportedCard, subtitle: String) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                BankMark(bank: card.bank, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subtitle)
                        .font(.app(11.5))
                        .foregroundStyle(Theme.muted)
                    Text(card.nickname)
                        .font(.app(15, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                    if let l4 = card.last4 {
                        Text("•••• \(l4)")
                            .font(.app(11))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
            }
            .padding(16)
            .surfaceCard(cornerRadius: 18)

            PrimaryButton(title: "Yes, that's it", action: { onResolved(card) })

            Button {
                withAnimation(toggleAnim) { creatingNew = true }
            } label: {
                Text("It's a different card")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .underline()
            }
            .buttonStyle(.plain)
        }
    }

    private func selectRow(_ card: ImportedCard) -> some View {
        Button { onResolved(card) } label: {
            HStack(spacing: 12) {
                BankMark(bank: card.bank, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.nickname)
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(Theme.cream)
                    if let l4 = card.last4 {
                        Text("•••• \(l4)")
                            .font(.app(10.5))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }

    private var addNewRow: some View {
        Button {
            withAnimation(toggleAnim) { creatingNew = true }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.accent)
                Text("None of these — add a new card")
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledField(label: "Bank", text: $bankName)
            labeledField(label: last4 == nil ? "Nickname (required)" : "Nickname", text: $nickname)

            HStack(spacing: 8) {
                Text("TYPE")
                    .font(.app(10, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Chip(label: "Credit", isOn: accountType == .credit) { accountType = .credit }
                Chip(label: "Debit", isOn: accountType == .debit) { accountType = .debit }
            }

            HStack(spacing: 10) {
                BankMark(bank: bankName, size: 26)
                if let l4 = last4 {
                    Text("Detected card ending •••• \(l4)")
                        .font(.app(11))
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("No card number on this statement — a nickname helps us tell your cards apart.")
                        .font(.app(11))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16)
        .surfaceCard(cornerRadius: 18)
    }

    private func labeledField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.app(10, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.muted)
            TextField("", text: text)
                .font(.app(14, weight: .semibold))
                .foregroundStyle(Theme.cream)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
    }
}

// MARK: - Preview (rows + warnings) before committing

private struct PreviewStep: View {
    let statement: ParsedStatement
    let bank: String
    let card: ImportedCard
    /// Non-nil for CSV sources — reopens the column-mapping step.
    var onAdjustMapping: (() -> Void)? = nil
    /// Receives the user-corrected statement (edits applied, excluded rows
    /// dropped) — what the analyzer actually gets.
    var onContinue: (ParsedStatement) -> Void

    /// One correctable row. Edits and exclusions live here until Continue
    /// rebuilds the statement from what's still included.
    private struct EditableRow: Identifiable {
        let id = UUID()
        var tx: ParsedTransaction
        var included = true
    }

    @State private var rows: [EditableRow] = []
    @State private var editingRow: EditableRow? = nil
    @State private var duplicateCount: Int = 0

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private var includedCount: Int { rows.filter(\.included).count }

    private var editedStatement: ParsedStatement {
        ParsedStatement(
            bankHint: statement.bankHint,
            accountLast4: statement.accountLast4,
            statementCurrency: statement.statementCurrency,
            period: statement.period,
            transactions: rows.filter(\.included).map(\.tx),
            warnings: statement.warnings
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Here's what we found")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.cream)

            Text("Tap any row to fix it, or untick rows that shouldn't count.")
                .font(.app(11))
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    summaryCard
                    if !statement.warnings.isEmpty { warningsCallout }
                    rowsCard
                    if let onAdjustMapping {
                        Button(action: onAdjustMapping) {
                            HStack(spacing: 8) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Columns look wrong? Adjust the mapping")
                                    .font(.app(11.5, weight: .semibold))
                            }
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle(scale: 0.97))
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 12)
            }

            PrimaryButton(
                title: "Looks right — analyze",
                isDisabled: includedCount == 0,
                action: { onContinue(editedStatement) }
            )
            .padding(.top, 8)
        }
        .onAppear {
            if rows.isEmpty {
                rows = statement.transactions.map { EditableRow(tx: $0) }
            }
        }
        .sheet(item: $editingRow) { row in
            RowEditSheet(tx: row.tx) { edited in
                if let index = rows.firstIndex(where: { $0.id == row.id }) {
                    rows[index].tx = edited
                }
            }
        }
        .task { await computeDuplicateCount() }
    }

    /// Counted at preview time (before the user commits to analysis) so the
    /// "will be skipped" figure is a promise made before the decision, not
    /// an after-the-fact reveal — matches what AnalyzeStep will actually do
    /// with the same card's existing fingerprints.
    private func computeDuplicateCount() async {
        let existing = await AppStore.shared.existingFingerprints(forCard: card.id)
        let cardID = card.id.uuidString
        duplicateCount = statement.transactions.reduce(into: 0) { count, tx in
            if existing.contains(Fingerprint.make(cardID: cardID, tx: tx)) { count += 1 }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BankMark(bank: bank, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.nickname)
                        .font(.app(15, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                    Text(bank)
                        .font(.app(11))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            HStack {
                statPair(label: "PERIOD", value: periodText)
                Spacer()
                statPair(label: "CURRENCY", value: statement.statementCurrency ?? "—")
                Spacer()
                statPair(label: "ROWS", value: "\(statement.transactions.count)")
            }
            if duplicateCount > 0 {
                Text("\(duplicateCount) already imported — will be skipped")
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Theme.accentHot)
            }
        }
        .padding(16)
        .surfaceCard(cornerRadius: 18)
    }

    private var periodText: String {
        guard let period = statement.period else { return "—" }
        return "\(Self.dateFormatter.string(from: period.lowerBound)) – \(Self.dateFormatter.string(from: period.upperBound))"
    }

    private func statPair(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.app(9, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.app(12, weight: .semibold))
                .foregroundStyle(Theme.cream)
        }
    }

    private var warningsCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accentHot)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(statement.warnings, id: \.self) { w in
                    Text(w)
                        .font(.app(11))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.accentHot.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accentHot.opacity(0.3), lineWidth: 1))
    }

    private var rowsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(includedCount) OF \(rows.count) ROWS INCLUDED")
                .font(.app(10, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.muted)
            ForEach($rows) { $row in
                HStack(spacing: 10) {
                    // Include/exclude tick — the whole left zone toggles.
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { row.included.toggle() }
                    } label: {
                        Image(systemName: row.included ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(row.included ? Theme.accent : Theme.muted.opacity(0.5))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.9))

                    // The row itself opens the fix-it sheet.
                    Button {
                        editingRow = row
                    } label: {
                        HStack {
                            Text(Self.dateFormatter.string(from: row.tx.date))
                                .frame(width: 74, alignment: .leading)
                            Text(row.tx.description)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(amountText(row.tx))
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(row.included ? Theme.muted : Theme.muted.opacity(0.4))
                        .strikethrough(!row.included, color: Theme.muted.opacity(0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.99))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .surfaceCard(cornerRadius: 16)
    }

    private func amountText(_ tx: ParsedTransaction) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: tx.amount).doubleValue)
    }
}

// MARK: - Row fix-it sheet

/// Corrects one parsed row before analysis — date, description, amount.
/// The statement is the user's own data; letting them fix a mis-read beats
/// silently importing it wrong.
private struct RowEditSheet: View {
    let tx: ParsedTransaction
    var onSave: (ParsedTransaction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = .now
    @State private var descriptionText: String = ""
    @State private var amountText: String = ""

    private var parsedAmount: Decimal? {
        Decimal(string: amountText.replacingOccurrences(of: ",", with: ""))
    }

    var body: some View {
        ZStack {
            AppBackdrop()

            VStack(alignment: .leading, spacing: 16) {
                Text("Fix this row")
                    .font(.app(20, weight: .heavy))
                    .foregroundStyle(Theme.cream)
                    .padding(.top, 24)

                VStack(alignment: .leading, spacing: 14) {
                    fieldLabel("DATE")
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(Theme.accent)

                    fieldLabel("DESCRIPTION")
                    TextField("", text: $descriptionText)
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(Theme.cream)
                        .padding(12)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    fieldLabel("AMOUNT (\(tx.currency ?? "statement currency"))")
                    TextField("", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.app(13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.cream)
                        .padding(12)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(18)
                .surfaceCard(cornerRadius: 20)

                PrimaryButton(title: "Save row", isDisabled: parsedAmount == nil || descriptionText.trimmingCharacters(in: .whitespaces).isEmpty) {
                    guard let amount = parsedAmount else { return }
                    onSave(ParsedTransaction(
                        date: date,
                        description: descriptionText.trimmingCharacters(in: .whitespaces),
                        amount: amount,
                        currency: tx.currency,
                        originalAmount: tx.originalAmount,
                        originalCurrency: tx.originalCurrency,
                        cardLast4: tx.cardLast4,
                        rawLine: tx.rawLine
                    ))
                    dismiss()
                }

                Button("Cancel") { dismiss() }
                    .font(.app(12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)

                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            date = tx.date
            descriptionText = tx.description
            amountText = String(format: "%.2f", NSDecimalNumber(decimal: tx.amount).doubleValue)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.app(9.5, weight: .semibold))
            .kerning(1.2)
            .foregroundStyle(Theme.muted)
    }
}

// MARK: - Analyze (scan-bar feel, then commit + hand back to onboarding)

private struct AnalyzeStep: View {
    let statement: ParsedStatement
    let card: ImportedCard
    let tripID: UUID?
    let homeCountry: String
    let homeCurrency: String
    var onFinished: (AnalysisResult) -> Void

    @State private var progress: Double = 0
    @State private var result: AnalysisResult? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Running the numbers")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.cream)

            Text("Using date-matched ECB rates when available. Offline estimates are labelled and update automatically.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 8)

            Spacer(minLength: 24)

            scanCard

            if let result {
                resultSummary(result)
                    .padding(.top, 16)
                    .transition(.opacity)
            }

            Spacer(minLength: 24)
        }
        .task { await run() }
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analysing \(statement.transactions.count) transaction\(statement.transactions.count == 1 ? "" : "s")…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.cream.opacity(0.85))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accentHot],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glass(cornerRadius: 16)
    }

    private func resultSummary(_ result: AnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Found \(result.foreignCount) foreign charge\(result.foreignCount == 1 ? "" : "s").")
                .font(.app(13, weight: .semibold))
                .foregroundStyle(Theme.cream)
            if result.duplicatesSkipped > 0 {
                Text("\(result.duplicatesSkipped) duplicate\(result.duplicatesSkipped == 1 ? "" : "s") already on file — skipped.")
                    .font(.app(12))
                    .foregroundStyle(Theme.muted)
            }
            if result.flaggedCount > 0 {
                Text("\(result.flaggedCount) look overpriced.")
                    .font(.app(12, weight: .semibold))
                    .foregroundStyle(Theme.loss)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .surfaceCard(cornerRadius: 16)
    }

    private func run() async {
        let duration = reduceMotion ? 0.3 : 1.8
        let start = Date()
        while !Task.isCancelled {
            let p = min(1, Date().timeIntervalSince(start) / duration)
            progress = p
            if p >= 1 { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        progress = 1

        let existing = await AppStore.shared.existingFingerprints(forCard: card.id)
        let analyzed = await Analyzer.analyze(
            statement: statement, card: card, homeCountry: homeCountry,
            homeCurrency: homeCurrency, existingFingerprints: existing,
            rateRepository: AppStore.shared.historicalRateRepository
        )
        guard !Task.isCancelled else { return }
        await AppStore.shared.commitImport(result: analyzed, card: card)
        if let tripID {
            await AppStore.shared.attach(result: analyzed, card: card, to: tripID)
        }
        withAnimation(.easeOut(duration: 0.3)) { result = analyzed }
        try? await Task.sleep(nanoseconds: reduceMotion ? 300_000_000 : 1_100_000_000)
        onFinished(analyzed)
    }
}

// MARK: - Exact card product (catalogue confirmation)

/// "Which \(bank) card exactly?" — the catalogue's exact-card picker.
/// Bank-level recognition already drives the analysis; confirming the exact
/// product improves published-fee breakdowns and future advice, so both
/// escape hatches ("not listed" / "not sure") proceed without blocking.
/// A previously confirmed (institution + last4) mapping preselects itself.
private struct CardProductStep: View {
    let card: ImportedCard
    /// The exact catalogue institution confirmed in the bank step — passed
    /// through, never re-derived from the name (a cross-market pick like
    /// "HSBC UK" must show HSBC UK's cards, not the home market's HSBC).
    let institution: Institution
    var onDone: () -> Void

    @State private var search = ""
    @State private var selectedProductID: String? = nil
    @State private var appeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A remembered confirmation for this institution+last4 — preselected
    /// with its provenance shown, never silently assumed.
    private var rememberedLink: UserCardLink? {
        UserCardLink.match(
            institutionID: institution.id, last4: card.last4,
            in: AppStore.shared.userCardLinks
        )
    }

    private var products: [CardProduct] {
        CardCatalog.searchProducts(institutionID: institution.id, query: search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Which \(institution.brand) card exactly?")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.cream)

            Text("Optional — it sharpens your fee breakdown and next-trip advice. The analysis runs either way.")
                .font(.app(12.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 8)

            if rememberedLink != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.good)
                    Text("You confirmed this card before — preselected.")
                        .font(.app(11.5))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 10)
            }

            searchField
                .padding(.top, 14)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(products) { product in
                        productRow(product)
                    }
                    if products.isEmpty {
                        Text("No matches — try fewer letters, or continue without picking.")
                            .font(.app(12))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 12)
            }

            PrimaryButton(title: selectedProductID == nil ? "Continue" : "Confirm card", trailingIcon: nil) {
                if let selectedProductID {
                    AppStore.shared.upsertUserCardLink(UserCardLink(
                        institutionID: institution.id,
                        last4: card.last4,
                        productID: selectedProductID,
                        nickname: card.nickname,
                        source: .manual
                    ))
                }
                onDone()
            }
            .padding(.top, 8)

            HStack(spacing: 18) {
                skipLink("My card isn't listed")
                skipLink("I'm not sure")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .onAppear {
            selectedProductID = rememberedLink?.productID
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85)) {
                appeared = true
            }
        }
        .sensoryFeedback(.selection, trigger: selectedProductID)
    }

    private func skipLink(_ label: String) -> some View {
        Button(action: onDone) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .underline()
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
            TextField("Search \(institution.brand) cards", text: $search)
                .font(.app(13.5))
                .foregroundStyle(Theme.cream)
                .tint(Theme.accent)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func productRow(_ product: CardProduct) -> some View {
        let isOn = selectedProductID == product.id
        return Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.7)) {
                selectedProductID = isOn ? nil : product.id
            }
        } label: {
            HStack(spacing: 12) {
                BankMark(bank: institution.brand, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.name)
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(Theme.cream)
                    HStack(spacing: 6) {
                        if let network = product.network {
                            Text(network)
                        }
                        Text(product.kind == .credit ? "Credit" : "Debit")
                        if !product.isActive {
                            Text("Legacy")
                                .foregroundStyle(Theme.loss.opacity(0.8))
                        }
                    }
                    .font(.app(10.5))
                    .foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.accent : Theme.muted.opacity(0.5))
                    .scaleEffect(isOn ? 1.08 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isOn ? Theme.accent.opacity(0.1) : Theme.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isOn ? Theme.accent.opacity(0.55) : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }
}
