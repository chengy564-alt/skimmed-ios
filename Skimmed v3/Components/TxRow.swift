import SwiftUI

/// One transaction line: flag, merchant, date (+ optional "estimated" badge),
/// loss amount. On the Reveal the amount is blurred (real native `.blur`);
/// on Home it's shown in the clear. Pass `onTap` to make the row a button
/// (opens the math sheet) — nil keeps it inert, so locked Reveal rows stay
/// non-interactive.
struct TxRow: View {
    let tx: Transaction
    var blurAmount: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { row }
                .buttonStyle(PressStyle(scale: 0.98))
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Text(tx.displayCountry.map(Derive.flag) ?? "💱")
                .font(.system(size: 17))

            VStack(alignment: .leading, spacing: 2) {
                Text(tx.merchantName)
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Derive.fmtDate(tx.txDate))
                        .font(.app(10.5))
                        .foregroundStyle(Theme.muted)
                    if tx.isForeign && !tx.isMarkupCalculable {
                        RateEvidenceBadge(text: "Not enough data", provisional: true)
                    } else if tx.markupConfidence == .estimated {
                        EstimatedBadge()
                    }
                }
            }

            Spacer(minLength: 8)

            // Zero markup (domestic rows, unpriceable rows) isn't a loss —
            // show a quiet dash instead of a red "−HK$0.00".
            Text(amountText)
                .font(.app(13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(amountColor)
                .blur(radius: blurAmount ? 6 : 0)
                .animation(.easeOut(duration: 0.6), value: blurAmount)

            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.muted.opacity(0.6))
            }
        }
    }

    private var amountText: String {
        if tx.markupAmount > 0 {
            return "−" + Derive.fmtMoney(tx.markupAmount, decimals: 2)
        }
        if tx.markupAmount < 0 {
            return "+" + Derive.fmtMoney(abs(tx.markupAmount), decimals: 2)
        }
        return "—"
    }

    private var amountColor: Color {
        if tx.markupAmount > 0 { return Theme.loss }
        if tx.markupAmount < 0 { return Theme.good }
        return Theme.muted
    }
}

/// Small amber "ESTIMATED" capsule — DCC reverse-estimates are surfaced
/// honestly, per the data model's `markup_confidence`.
struct EstimatedBadge: View {
    var body: some View {
        Text("ESTIMATED")
            .font(.app(8, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accent.opacity(0.15), in: Capsule())
    }
}

/// Compact provenance/confidence label that reuses the app's existing capsule
/// language. It remains subordinate to the amount and recommendation itself.
struct RateEvidenceBadge: View {
    let text: String
    let provisional: Bool

    var body: some View {
        Text(text.uppercased())
            .font(.app(8, weight: .bold))
            .kerning(0.5)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(provisional ? Theme.accent : Theme.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (provisional ? Theme.accent : Color.white).opacity(0.12),
                in: Capsule()
            )
    }
}
