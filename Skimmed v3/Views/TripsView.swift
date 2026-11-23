import SwiftUI

/// Trips — the auto-detected trip history. The live trip is pinned on top
/// in the Home trip-card treatment; closed trips stack below as a timeline,
/// newest first. Reads `AppStore` (derived from imported statements).
struct TripsView: View {

    /// A country routed from Home's leak map — consumed on appear/change:
    /// opens the newest matching trip (planned audit first, then detected).
    @Binding var pendingCountry: String?

    init(pendingCountry: Binding<String?> = .constant(nil)) {
        _pendingCountry = pendingCountry
    }

    @ObservedObject private var appStore = AppStore.shared
    @AppStorage("profile.tripFreq") private var storedTripFreq: String = ""
    @AppStorage("profile.destinations") private var storedDestinations: String = ""

    @State private var appeared = false
    @State private var pulse = false
    @State private var selectedTrip: Trip? = nil
    @State private var selectedPlannedTripID: UUID? = nil
    @State private var showNewTrip = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Derived from AppStore

    private var live: Trip? { appStore.liveTrip }

    private var plannedTrips: [PlannedTrip] {
        appStore.plannedTrips.sorted { $0.startDate > $1.startDate }
    }

    private var pastTrips: [Trip] {
        appStore.trips
            .filter { $0.endDate != nil }
            .sorted { $0.startDate > $1.startDate }
    }

    private func liveDay(_ trip: Trip) -> Int {
        max(1, Derive.daysBetween(trip.startDate, Derive.isoToday) + 1)
    }

    private var totalAllTrips: Double {
        Derive.round2(appStore.trips.reduce(0) { $0 + $1.totalMarkupThisTrip })
    }

    /// A trip's charges are its TIME WINDOW's foreign rows — the same rule
    /// TripBuilderCore uses for the trip's total, so a Tokyo trip with a
    /// Bangkok stopover shows (and sums) the stopover too instead of a
    /// total that doesn't match its own charge list.
    private func txs(for trip: Trip) -> [Transaction] {
        appStore.transactions.filter {
            $0.isForeign
                && $0.txDate >= trip.startDate
                && (trip.endDate == nil || $0.txDate <= trip.endDate!)
        }
    }

    private func city(for trip: Trip) -> String { "\(trip.destinationCurrency) spending" }

    private var destinations: [String] {
        storedDestinations.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            tripsList

            // Custom overlay push — the floating nav stays live underneath.
            if let trip = selectedTrip {
                TripDetailView(
                    trip: trip,
                    city: city(for: trip),
                    txs: txs(for: trip),
                    onBack: {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                            selectedTrip = nil
                        }
                    }
                )
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
                .zIndex(2)
            }

            if let tripID = selectedPlannedTripID {
                PlannedTripDetailView(
                    tripID: tripID,
                    onBack: {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                            selectedPlannedTripID = nil
                        }
                    }
                )
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
                .zIndex(2)
            }
        }
        .sensoryFeedback(.selection, trigger: selectedTrip?.id) { _, new in
            new != nil // tick on open, not on back-dismiss
        }
        .sensoryFeedback(.selection, trigger: selectedPlannedTripID) { _, new in
            new != nil
        }
        .onAppear { consumePendingCountry() }
        .onChange(of: pendingCountry) { _, _ in consumePendingCountry() }
        .fullScreenCover(isPresented: $showNewTrip) {
            NewTripFlow(
                onCreated: { trip in
                    showNewTrip = false
                    // Land straight in the new trip's audit page.
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        selectedPlannedTripID = trip.id
                    }
                },
                onCancel: { showNewTrip = false }
            )
        }
    }

    private var tripsList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                header
                    .padding(.top, 12)

                if let live {
                    liveCard(live)
                } else if pastTrips.isEmpty {
                    preHistoryCards
                }

                if !plannedTrips.isEmpty {
                    Text("TRIP AUDITS")
                        .font(.app(13, weight: .bold))
                        .kerning(1.4)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)

                    VStack(spacing: 12) {
                        ForEach(plannedTrips) { trip in
                            plannedTripRow(trip)
                        }
                    }
                }

                Text("PAST TRIPS")
                    .font(.app(13, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                if pastTrips.isEmpty {
                    Text("No trips yet — they'll show up here once we spot foreign charges on an import.")
                        .font(.app(12))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(pastTrips.enumerated()), id: \.element.id) { index, trip in
                            pastTripRow(trip)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 20)
                                .animation(
                                    .spring(response: 0.5, dampingFraction: 0.8)
                                        .delay(0.1 + Double(index) * 0.07),
                                    value: appeared
                                )
                        }
                    }
                }

                if !appStore.trips.isEmpty {
                    Text("Lost \(Derive.fmtMoney(totalAllTrips)) across \(appStore.trips.count) trips")
                        .font(.app(11))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 140) // room for the floating nav
        }
        .onAppear {
            appeared = true
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your")
                    .font(.app(27, weight: .heavy))
                    .foregroundStyle(Theme.cream)
                Text("Trips")
                    .font(.app(27, weight: .heavy))
                    .foregroundStyle(Theme.cream)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        newTripButton
                        AddStatementPill()
                        detectedPill
                    }
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            newTripButton
                            AddStatementPill()
                        }
                        detectedPill
                    }
                }
                Text("From your card activity")
                    .font(.app(10))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - Pre-history destination prep cards (real mode, no trips yet)

    private var preHistoryCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GET READY FOR YOUR NEXT TRIP")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            if destinations.isEmpty {
                Text("Tell us where you usually go from Profile, and we'll get your cards ready.")
                    .font(.app(12))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
            } else {
                ForEach(destinations, id: \.self) { dest in
                    destinationPrepCard(dest)
                }
            }
        }
    }

    private func destinationPrepCard(_ token: String) -> some View {
        let info = Derive.destinationInfo(token)
        let flag = info.map { Derive.flag($0.country) } ?? "🏳️"
        let currency = info?.currency ?? "local currency"
        let name = info.map { CountryCatalog.name(for: $0.country) } ?? token
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(flag)
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.app(14, weight: .bold))
                        .foregroundStyle(Theme.cream)
                    Text("Likely currency: \(currency)")
                        .font(.app(10.5))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            Text("Import a statement after this trip to see which card was cheapest — check Cards for your line-up.")
                .font(.app(11))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
        }
        .padding(16)
        .surfaceCard(cornerRadius: 18)
    }

    // MARK: - Live trip hero

    private func liveCard(_ live: Trip) -> some View {
        let tripTxs = txs(for: live)
        let dccCount = tripTxs.filter(\.isDccSuspected).count
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .opacity(pulse ? 0.25 : 1)
                    Text("LATEST")
                        .font(.app(10, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.accent.opacity(0.15), in: Capsule())

                Spacer()

                Text("Day \(liveDay(live))")
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }

            Text("\(city(for: live)) 💱")
                .font(.app(26, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .padding(.top, 12)

            Text("Started \(Derive.fmtDate(live.startDate)) · \(tripTxs.count) charges")
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
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("DCC TRAPS")
                        .font(.app(9.5, weight: .semibold))
                        .kerning(1.3)
                        .foregroundStyle(Theme.muted)
                    Text("\(dccCount)")
                        .font(.app(20, weight: .bold))
                        .foregroundStyle(Theme.cream)
                }
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            ZStack(alignment: .topTrailing) {
                Theme.surface
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

    /// Route only to a trip whose country the user explicitly selected.
    /// Currency-clustered detected trips are never treated as proof of place.
    private func consumePendingCountry() {
        guard let country = pendingCountry else { return }
        pendingCountry = nil
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            if let planned = plannedTrips.first(where: { $0.destinationCountry == country }) {
                selectedPlannedTripID = planned.id
            }
        }
    }

    private var detectedPill: some View {
        Text("\(appStore.trips.count) DETECTED")
            .font(.app(9.5, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(Theme.accent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.accent.opacity(0.15), in: Capsule())
    }

    // MARK: - New trip control + planned trip rows

    /// Compact glass/amber "+ New trip" — full 44pt hit area, selection
    /// haptic, springy press.
    private var newTripButton: some View {
        Button {
            showNewTrip = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("NEW TRIP")
                    .font(.app(9.5, weight: .bold))
                    .kerning(0.5)
            }
            .foregroundStyle(Theme.onAccent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.buttonGradient, in: Capsule())
            .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 4)
            // Real 44pt hit target: the frame carries the touch area — a
            // negative-inset contentShape doesn't reliably receive touches
            // outside the label's bounds on device.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .sensoryFeedback(.selection, trigger: showNewTrip)
    }

    private func plannedTripRow(_ trip: PlannedTrip) -> some View {
        let attached = appStore.cards.filter { trip.attachedCardIDs.contains($0.id) }
        let stage = trip.stage(coveredCards: attached.map(\.nickname))
        let ids = Set(trip.transactionIDs)
        let loss = appStore.calculationTransactions
            .filter { ids.contains($0.id) && $0.isForeign && $0.confidence != .unableToCalculate }
            .reduce(0.0) {
                $0 + max(0, NSDecimalNumber(decimal: $1.markupAmount ?? 0).doubleValue)
            }
        let (stageText, stageTint): (String, Color) = {
            switch stage {
            case .planning: return ("AWAITING STATEMENTS", Theme.muted)
            case .partial: return ("PARTIAL", Theme.accent)
            case .complete: return ("AUDITED", Theme.good)
            }
        }()

        return Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                selectedPlannedTripID = trip.id
            }
        } label: {
            HStack(spacing: 14) {
                Text(Derive.flag(trip.destinationCountry))
                    .font(.system(size: 24))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.05), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(trip.label ?? Locale(identifier: "en_US").localizedString(forRegionCode: trip.destinationCountry) ?? trip.destinationCountry)
                        .font(.app(14, weight: .bold))
                        .foregroundStyle(Theme.cream)
                        .lineLimit(1)
                    Text(stageText)
                        .font(.app(9, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(stageTint)
                }

                Spacer(minLength: 8)

                if stage != .planning {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("−\(Derive.fmtMoney(loss))")
                            .font(.app(14, weight: .bold))
                            .foregroundStyle(Theme.loss)
                        Text("lost")
                            .font(.app(10))
                            .foregroundStyle(Theme.muted)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted.opacity(0.6))
            }
            .padding(16)
            .surfaceCard(cornerRadius: 18)
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }

    // MARK: - Past trip rows

    private func pastTripRow(_ trip: Trip) -> some View {
        let count = txs(for: trip).count
        return Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                selectedTrip = trip
            }
        } label: {
            HStack(spacing: 14) {
                Text("💱")
                    .font(.system(size: 24))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.05), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(city(for: trip))
                        .font(.app(14, weight: .bold))
                        .foregroundStyle(Theme.cream)
                    Text("\(Derive.fmtDate(trip.startDate)) – \(Derive.fmtDate(trip.endDate ?? trip.startDate)) · \(count) charges")
                        .font(.app(10.5))
                        .foregroundStyle(Theme.muted)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("−\(Derive.fmtMoney(trip.totalMarkupThisTrip))")
                        .font(.app(14, weight: .bold))
                        .foregroundStyle(Theme.loss)
                    Text("lost")
                        .font(.app(10))
                        .foregroundStyle(Theme.muted)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted.opacity(0.6))
            }
            .padding(16)
            .surfaceCard(cornerRadius: 18)
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }
}
