import SwiftUI

/// Stat pattern: uppercase label, big bold number, change pill, sub-caption.
/// Pass `countTo` (+ optional `countPrefix`) to render the value as a
/// scroll-triggered count-up instead of static text.
struct StatCard: View {
    enum PillTone {
        case good, bad
    }

    let label: String
    let value: String
    var countTo: Double? = nil
    var countPrefix: String = ""
    var pill: String? = nil
    var pillTone: PillTone = .bad
    var sub: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                statValue
                    .font(.app(26, weight: .bold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let pill {
                    Text(pill)
                        .font(.app(10, weight: .bold))
                        .foregroundStyle(pillTone == .good ? Theme.good : Theme.bad)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (pillTone == .good ? Theme.good : Theme.bad).opacity(0.15),
                            in: Capsule()
                        )
                }
            }
            if let sub {
                Text(sub)
                    .font(.app(11))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .surfaceCard()
    }

    @ViewBuilder
    private var statValue: some View {
        if let countTo {
            CountUpText(
                to: countTo,
                duration: 1.3,
                prefix: countPrefix,
                startOnScrollVisible: true
            )
        } else {
            Text(value)
        }
    }
}
