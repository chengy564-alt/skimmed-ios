import SwiftUI

/// One trip, drilled open — the hero in the live-trip treatment, then every
/// charge from that trip as tappable rows into the math sheet. Slides in
/// over TripsView (custom overlay push, no NavigationStack); the floating
/// nav stays live underneath.
struct TripDetailView: View {
    let trip: Trip
    let city: String
    let txs: [Transaction]
    var onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var selectedTx: Transaction? = nil

    private var sortedTxs: [Transaction] {
        txs.sorted { $0.txDate > $1.txDate }
    }

    private var dccCount: Int {
        txs.filter(\.isDccSuspected).count
    }

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                        .padding(.top, 12)

                    heroCard

                    Text("CHARGES")
                        .font(.app(13, weight: .bold))
                        .kerning(1.4)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)

                    VStack(spacing: 14) {
                        ForEach(Array(sortedTxs.enumerated()), id: \.element.id) { index, tx in
                            TxRow(tx: tx, blurAmount: false, onTap: { selectedTx = tx })
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared || reduceMotion ? 0 : 14)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.85)
                                        .delay(0.15 + Double(index) * 0.05),
                                    value: appeared
                                )
                        }
                    }
                    .padding(20)
                    .surfaceCard()

                    Text("Tap any charge to see the math")
                        .font(.app(10.5))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 140) // room for the floating nav
            }
        }
        .onAppear { appeared = true }
        .sheet(item: $selectedTx) { tx in
            TxDetailSheet(tx: tx)
        }
    }

    // MARK: - Header (custom back, SettingsView style)

    private var header: some View {
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

            Text(city)
                .font(.app(20, weight: .heavy))
                .foregroundStyle(Theme.cream)

            Spacer()
        }
    }

    // MARK: - Hero (live-trip card treatment)

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("💱")
                    .font(.system(size: 34))
                Spacer()
                Text("\(Derive.fmtDate(trip.startDate)) – \(Derive.fmtDate(trip.endDate ?? trip.startDate))")
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }

            Text(city)
                .font(.app(26, weight: .heavy))
                .foregroundStyle(Theme.cream)
                .padding(.top, 10)

            Text("\(txs.count) charges on this trip")
                .font(.app(11.5))
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LOST THIS TRIP")
                        .font(.app(9.5, weight: .semibold))
                        .kerning(1.3)
                        .foregroundStyle(Theme.muted)
                    Text(Derive.fmtMoney(trip.totalMarkupThisTrip))
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
}
