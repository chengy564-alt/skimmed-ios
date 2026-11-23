import SwiftUI
import UniformTypeIdentifiers

// MARK: - New trip flow (Feature 1)

/// Creates a completed-trip audit: destination + dates + the cards used,
/// then lands in the trip's audit page where statements attach one by one.
/// One considered glass form instead of a five-screen wizard — the statement
/// window and coverage checklist live on the audit page, which is where the
/// user returns after every import.
struct NewTripFlow: View {
    var onCreated: (PlannedTrip) -> Void
    var onCancel: () -> Void

    @State private var search = ""
    @State private var destinationCountry: String? = nil
    @State private var label = ""
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var expectedCardInput = ""
    @State private var expectedCards: [String] = []
    @State private var appeared = false

    @ObservedObject private var appStore = AppStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var springAnim: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.82)
    }

    /// Popular destinations first (the curated set with flags/city names),
    /// then every ISO region, both searchable by localized name.
    private var regionCodes: [String] {
        let popular = ["JP", "TH", "TW", "SG", "KR", "CN", "US", "GB", "HK", "AU", "CA", "FR", "IT", "ES"]
        let rest = Locale.Region.isoRegions.map(\.identifier)
            .filter { $0.count == 2 && !popular.contains($0) }
            .sorted { regionName($0) < regionName($1) }
        let all = popular + rest
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { regionName($0).lowercased().contains(q) }
    }

    private func regionName(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
    }

    private var canCreate: Bool {
        destinationCountry != nil && startDate <= endDate
    }

    private var window: TripPlanCore.StatementWindow? {
        guard destinationCountry != nil else { return nil }
        return TripPlanCore.statementWindow(start: startDate, end: endDate)
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("New trip")
                        .font(.app(24, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                    Spacer()
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
                .padding(.bottom, 4)

                Text("Audit a trip you've already taken — every card, every hidden markup.")
                    .font(.app(12.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        destinationCard
                        datesCard
                        cardsCard

                        if let window {
                            windowCard(window)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 16)
                    .animation(springAnim, value: destinationCountry)
                }

                PrimaryButton(title: "Create trip", isDisabled: !canCreate) {
                    guard let destinationCountry else { return }
                    let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
                    let trip = PlannedTrip(
                        destinationCountry: destinationCountry,
                        label: trimmedLabel.isEmpty ? nil : trimmedLabel,
                        startDate: startDate,
                        endDate: endDate,
                        expectedCards: expectedCards
                    )
                    appStore.upsertPlannedTrip(trip)
                    onCreated(trip)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.35)) { appeared = true }
        }
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("WHERE DID YOU GO?")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                TextField("Search countries", text: $search)
                    .font(.app(13.5))
                    .foregroundStyle(Theme.cream)
                    .tint(Theme.accent)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(regionCodes.prefix(30), id: \.self) { code in
                        Chip(
                            label: "\(Derive.flag(code)) \(regionName(code))",
                            isOn: destinationCountry == code
                        ) {
                            withAnimation(springAnim) { destinationCountry = code }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .padding(.horizontal, -4)
            .padding(.top, 10)

            TextField("Trip name (optional) — e.g. Tokyo, cherry blossom", text: $label)
                .font(.app(13))
                .foregroundStyle(Theme.cream)
                .tint(Theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .padding(.top, 10)
        }
        .padding(18)
        .surfaceCard(cornerRadius: 20)
    }

    private var datesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("WHEN?")

            HStack {
                Text("Trip start")
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                Spacer()
                DatePicker("", selection: $startDate, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            .padding(.top, 12)

            HStack {
                Text("Trip end")
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                Spacer()
                DatePicker("", selection: $endDate, in: startDate...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            .padding(.top, 8)
        }
        .padding(18)
        .surfaceCard(cornerRadius: 20)
        .colorScheme(.dark)
    }

    private var cardsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("WHICH CARDS DID YOU USE?")

            Text("List every card — the audit is only complete when each one's statement is in.")
                .font(.app(11.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 8)

            // Existing imported cards join with one tap.
            if !appStore.cards.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(appStore.cards) { card in
                        Chip(label: card.nickname, isOn: expectedCards.contains(card.nickname)) {
                            withAnimation(springAnim) {
                                if let i = expectedCards.firstIndex(of: card.nickname) {
                                    expectedCards.remove(at: i)
                                } else {
                                    expectedCards.append(card.nickname)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }

            HStack(spacing: 10) {
                TextField("Add a card — e.g. HSBC Red", text: $expectedCardInput)
                    .font(.app(13))
                    .foregroundStyle(Theme.cream)
                    .tint(Theme.accent)
                    .autocorrectionDisabled()
                    .onSubmit(addExpectedCard)
                Button(action: addExpectedCard) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressStyle(scale: 0.88))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .padding(.top, 12)

            if !expectedCards.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(expectedCards.filter { name in !appStore.cards.contains { $0.nickname == name } }, id: \.self) { name in
                        HStack(spacing: 6) {
                            Text(name)
                                .font(.app(12, weight: .semibold))
                                .foregroundStyle(Theme.cream)
                            Button {
                                withAnimation(springAnim) { expectedCards.removeAll { $0 == name } }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.muted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(18)
        .surfaceCard(cornerRadius: 20)
    }

    private func addExpectedCard() {
        let trimmed = expectedCardInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !expectedCards.contains(trimmed) else { return }
        withAnimation(springAnim) {
            expectedCards.append(trimmed)
            expectedCardInput = ""
        }
    }

    private func windowCard(_ window: TripPlanCore.StatementWindow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Statements you'll need")
                    .font(.app(12.5, weight: .bold))
                    .foregroundStyle(Theme.cream)
                Text(TripPlanCore.windowSentence(window))
                    .font(.app(11.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glass(cornerRadius: 16)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.app(10, weight: .semibold))
            .kerning(1.4)
            .foregroundStyle(Theme.muted)
    }
}

// MARK: - Planned trip audit page (Features 1+2+4)

/// A planned trip's audit: window + coverage checklist, per-card observed
/// losses, the playbook, and the charges — with "add statement" wired
/// straight into the existing import pipeline (tripID attach).
struct PlannedTripDetailView: View {
    let tripID: UUID
    var onBack: () -> Void

    @ObservedObject private var appStore = AppStore.shared
    @AppStorage("profile.homeCurrency") private var homeCurrency: String = RateProvider.defaultHomeCurrency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var isImporterPresented = false
    @State private var pickedFile: PickedStatementFile? = nil
    @State private var pickError: String? = nil
    @State private var selectedTx: Transaction? = nil
    @State private var confirmDelete = false

    struct PickedStatementFile: Identifiable {
        let id = UUID()
        let data: Data
        let filename: String
    }

    private var trip: PlannedTrip? {
        appStore.plannedTrips.first { $0.id == tripID }
    }

    /// View-facing rows for this trip (reuses TxRow/TxDetailSheet).
    private var tripTransactions: [Transaction] {
        guard let trip else { return [] }
        let ids = Set(trip.transactionIDs.map(\.uuidString))
        return appStore.transactions.filter { ids.contains($0.id) }
            .sorted { $0.txDate > $1.txDate }
    }

    private var tripImported: [ImportedTransaction] {
        guard let trip else { return [] }
        let ids = Set(trip.transactionIDs)
        return appStore.calculationTransactions.filter { ids.contains($0.id) }
    }

    private var attachedCards: [ImportedCard] {
        guard let trip else { return [] }
        return appStore.cards.filter { trip.attachedCardIDs.contains($0.id) }
    }

    private var missingCards: [String] {
        guard let trip else { return [] }
        return TripPlanCore.missingCards(expected: trip.expectedCards, covered: attachedCards.map(\.nickname))
    }

    private var totalLoss: Double {
        let priced = tripImported.filter {
            $0.isForeign && $0.confidence != .unableToCalculate
        }
        return NSDecimalNumber(decimal: priced.totalPositiveLoss).doubleValue
    }

    private var advice: TripAdvice? {
        guard let trip, !trip.attachedCardIDs.isEmpty else { return nil }
        return TripAdvice.build(
            trip: trip, transactions: appStore.calculationTransactions,
            cards: appStore.cards, links: appStore.userCardLinks,
            homeCurrency: homeCurrency, formatMoney: { Derive.fmtMoney($0) }
        )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    var body: some View {
        ZStack {
            AppBackdrop()

            if let trip {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        header(trip)
                            .padding(.top, 12)

                        heroCard(trip)
                        coverageCard(trip)

                        if let advice, !advice.lines.isEmpty {
                            playbookCard(advice)
                        }

                        if !tripTransactions.isEmpty {
                            chargesCard
                        }

                        deleteButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 140) // room for the floating nav
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.85)) {
                appeared = true
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.commaSeparatedText, .plainText, .pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    pickError = nil
                    pickedFile = PickedStatementFile(data: data, filename: url.lastPathComponent)
                } catch {
                    pickError = "Couldn't read that file — try another one."
                }
            case .failure:
                pickError = "Couldn't read that file — try another one."
            }
        }
        .fullScreenCover(item: $pickedFile) { file in
            ImportFlowView(
                fileData: file.data,
                filename: file.filename,
                tripID: tripID,
                onAnalyzed: { pickedFile = nil },
                onCancel: { pickedFile = nil }
            )
        }
        .sheet(item: $selectedTx) { tx in
            TxDetailSheet(tx: tx)
        }
        .confirmationDialog("Delete this trip?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete trip", role: .destructive) {
                appStore.deletePlannedTrip(id: tripID)
                onBack()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Removes the trip record. Imported cards and charges stay.")
        }
    }

    private func header(_ trip: PlannedTrip) -> some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.cream)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            Text(trip.label ?? regionName(trip.destinationCountry))
                .font(.app(20, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)

            Spacer()

            stageBadge(trip)
        }
    }

    private func regionName(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
    }

    private func stageBadge(_ trip: PlannedTrip) -> some View {
        let stage = trip.stage(coveredCards: attachedCards.map(\.nickname))
        let (text, tint): (String, Color) = {
            switch stage {
            case .planning: return ("AWAITING STATEMENTS", Theme.muted)
            case .partial: return ("PARTIAL", Theme.accent)
            case .complete: return ("AUDITED", Theme.good)
            }
        }()
        return Text(text)
            .font(.app(9, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private func heroCard(_ trip: PlannedTrip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Derive.flag(trip.destinationCountry))
                    .font(.system(size: 34))
                Spacer()
                Text("\(Self.dateFormatter.string(from: trip.startDate)) – \(Self.dateFormatter.string(from: trip.endDate))")
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }

            Text(regionName(trip.destinationCountry))
                .font(.app(26, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .padding(.top, 10)

            if trip.attachedCardIDs.isEmpty {
                Text("No statements yet — add the ones covering the trip window to run the audit.")
                    .font(.app(11.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                    .padding(.top, 8)
            } else {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LOST THIS TRIP")
                            .font(.app(9.5, weight: .semibold))
                            .kerning(1.3)
                            .foregroundStyle(Theme.muted)
                        Text(Derive.fmtMoney(totalLoss))
                            .font(.app(20, weight: .bold))
                            .foregroundStyle(Theme.loss)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DCC TRAPS")
                            .font(.app(9.5, weight: .semibold))
                            .kerning(1.3)
                            .foregroundStyle(Theme.muted)
                        Text("\(tripImported.filter(\.isDccSuspected).count)")
                            .font(.app(20, weight: .bold))
                            .foregroundStyle(Theme.cream)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CHARGES")
                            .font(.app(9.5, weight: .semibold))
                            .kerning(1.3)
                            .foregroundStyle(Theme.muted)
                        Text("\(tripTransactions.count)")
                            .font(.app(20, weight: .bold))
                            .foregroundStyle(Theme.cream)
                    }
                }
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            ZStack(alignment: .topTrailing) {
                Theme.surface
                RadialGradient(
                    colors: [Theme.accentHot.opacity(0.22), .clear],
                    center: .center, startRadius: 0, endRadius: 96
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

    private func coverageCard(_ trip: PlannedTrip) -> some View {
        let window = TripPlanCore.statementWindow(start: trip.startDate, end: trip.endDate)
        return VStack(alignment: .leading, spacing: 0) {
            Text("STATEMENT COVERAGE")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)

            Text(TripPlanCore.windowSentence(window))
                .font(.app(11.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 10)

            if !attachedCards.isEmpty || !missingCards.isEmpty {
                VStack(spacing: 8) {
                    ForEach(attachedCards) { card in
                        coverageRow(label: card.nickname, done: true)
                    }
                    ForEach(missingCards, id: \.self) { name in
                        coverageRow(label: name, done: false)
                    }
                }
                .padding(.top, 12)
            }

            if let pickError {
                Text(pickError)
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Theme.loss)
                    .padding(.top, 10)
            }

            PrimaryButton(
                title: missingCards.isEmpty
                    ? (attachedCards.isEmpty ? "Add the first statement" : "Add another statement")
                    : "Add a missing card's statement",
                leadingIcon: "lock.fill",
                trailingIcon: nil
            ) {
                isImporterPresented = true
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .surfaceCard(cornerRadius: 20)
    }

    private func coverageRow(label: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(done ? Theme.good : Theme.muted)
            Text(label)
                .font(.app(13, weight: .semibold))
                .foregroundStyle(done ? Theme.cream : Theme.muted)
            Spacer()
            Text(done ? "IMPORTED" : "MISSING")
                .font(.app(9, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(done ? Theme.good : Theme.loss)
        }
    }

    private func playbookCard(_ advice: TripAdvice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NEXT-TRIP PLAYBOOK")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(advice.lines) { line in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: line.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 20)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.title)
                                .font(.app(13, weight: .bold))
                                .foregroundStyle(Theme.cream)
                            Text(line.detail)
                                .font(.app(11.5))
                                .foregroundStyle(Theme.muted)
                                .lineSpacing(3)
                            Text(line.label.display.uppercased())
                                .font(.app(8.5, weight: .bold))
                                .kerning(0.6)
                                .foregroundStyle(labelTint(line.label))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(labelTint(line.label).opacity(0.13), in: Capsule())
                                .padding(.top, 3)
                        }
                    }
                }
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glass(cornerRadius: 20)
    }

    private func labelTint(_ label: EvidenceLabel) -> Color {
        switch label {
        case .observed: return Theme.good
        case .published: return Theme.accent
        case .estimated: return Theme.muted
        case .insufficient: return Theme.loss
        }
    }

    private var chargesCard: some View {
        VStack(spacing: 14) {
            Text("CHARGES ON THIS TRIP")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(tripTransactions) { tx in
                TxRow(tx: tx, blurAmount: false, onTap: { selectedTx = tx })
            }
        }
        .padding(20)
        .surfaceCard()
    }

    private var deleteButton: some View {
        Button { confirmDelete = true } label: {
            Text("Delete this trip")
                .font(.app(12))
                .foregroundStyle(Theme.loss.opacity(0.85))
                .underline()
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}
