import SwiftUI

/// "Tap any line to see the math" — the per-transaction breakdown sheet.
/// Three steps in the app's own voice: what they charged you, what the real
/// rate says it should have been, and the skim — counted up like a mini
/// Reveal with a soft thump when it lands. DCC-suspected rows get the
/// reverse-estimate explainer.
struct TxDetailSheet: View {
    let tx: Transaction

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var landed = false

    /// The foreign currency the money was actually spent in.
    private var localCurrency: String {
        tx.isDccSuspected ? (tx.localCurrencyInferred ?? tx.billedCurrency) : tx.billedCurrency
    }

    /// What the charge should have cost at the available reference rate.
    private var fairAmount: Double {
        tx.homeCurrencyAmount - tx.markupAmount
    }

    private var markupPct: Double {
        guard tx.midMarketRate > 0 else { return 0 }
        return (tx.effectiveRate / tx.midMarketRate - 1) * 100
    }

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .padding(.top, 28)

                    if !tx.isForeign {
                        stepCard(index: 0) {
                            stepContent(
                                eyebrow: "STATEMENT CHARGE",
                                amount: "\(fmtForeign(tx.billedAmount)) \(tx.billedCurrency)",
                                amountColor: Theme.cream,
                                sub: "Charged in your home currency."
                            )
                        }
                    } else if tx.isMarkupCalculable {
                        stepCard(index: 0) {
                            stepContent(
                                eyebrow: "THEY CHARGED YOU",
                                amount: Derive.fmtMoney(tx.homeCurrencyAmount, decimals: 2),
                                amountColor: Theme.cream,
                                sub: tx.isDccSuspected
                                    ? "straight in \(Derive.homeCurrencyCode) — no local currency on the slip"
                                    : "billed as \(fmtForeign(tx.billedAmount)) \(tx.billedCurrency)"
                            )
                        }
                    } else {
                        stepCard(index: 0) {
                            stepContent(
                                eyebrow: "STATEMENT CHARGE",
                                amount: "\(fmtForeign(tx.billedAmount)) \(tx.billedCurrency)",
                                amountColor: Theme.cream,
                                sub: "The amount and currency visible on the imported statement."
                            )
                        }
                    }

                    if !tx.isForeign {
                        stepCard(index: 1) {
                            stepContent(
                                eyebrow: "NO FX COMPARISON",
                                amount: "—",
                                amountColor: Theme.muted,
                                sub: "This is a home-currency purchase, so no foreign-exchange loss was calculated."
                            )
                        }
                    } else if tx.isMarkupCalculable {
                        stepCard(index: 1) {
                            stepContent(
                                eyebrow: "AT THE REFERENCE RATE",
                                amount: Derive.fmtMoney(fairAmount, decimals: 2),
                                amountColor: Theme.good,
                                sub: referenceRateExplanation
                            )
                        }

                        stepCard(index: 2) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(differenceTitle)
                                        .font(.app(10, weight: .semibold))
                                        .kerning(1.4)
                                        .foregroundStyle(Theme.muted)
                                    Spacer()
                                    Text(differencePercentageLabel)
                                        .font(.app(9.5, weight: .bold))
                                        .foregroundStyle(differenceColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(differenceColor.opacity(0.13), in: Capsule())
                                }

                                CountUpText(
                                    to: abs(tx.markupAmount),
                                    duration: reduceMotion ? 0 : 1.0,
                                    delay: 0.35,
                                    prefix: differencePrefix + Derive.moneySymbol,
                                    decimals: 2,
                                    onDone: { landed = true }
                                )
                                .font(.app(30, weight: .heavy))
                                .foregroundStyle(differenceColor)
                                .shadow(color: differenceColor.opacity(landed ? 0.45 : 0.2), radius: landed ? 16 : 10)
                            }
                        }
                    } else {
                        stepCard(index: 1) {
                            stepContent(
                                eyebrow: "NOT ENOUGH DATA",
                                amount: "—",
                                amountColor: Theme.muted,
                                sub: "This statement did not show both the foreign amount and the settled home amount, so Skimmed will not invent a loss."
                            )
                        }
                    }

                    if tx.isDccSuspected && tx.isMarkupCalculable {
                        dccCard
                            .opacity(appeared ? 1 : 0)
                            .animation(.easeOut(duration: 0.4).delay(0.5), value: appeared)
                    }

                    Text(methodologyCopy)
                        .font(.app(10.5))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { appeared = true }
        .sensoryFeedback(.impact(weight: .medium), trigger: landed)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(tx.displayCountry.map(Derive.flag) ?? "💱")
                .font(.system(size: 30))

            VStack(alignment: .leading, spacing: 5) {
                Text(tx.merchantName)
                    .font(.app(18, weight: .heavy))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(Derive.fmtDate(tx.txDate))
                        .font(.app(11))
                        .foregroundStyle(Theme.muted)
                    if tx.isForeign && !tx.isMarkupCalculable {
                        RateEvidenceBadge(text: "Not enough data", provisional: true)
                    } else if tx.markupConfidence == .estimated {
                        EstimatedBadge()
                    }
                }
                if tx.isMarkupCalculable && tx.isForeign && tx.midMarketRate > 0 {
                    HStack(spacing: 6) {
                        RateEvidenceBadge(
                            text: usesECBReference
                                ? "ECB daily rate"
                                : "Reference estimate · updates automatically",
                            provisional: !usesECBReference
                        )
                        if usesECBReference, let date = tx.referenceRateDate {
                            Text(Derive.fmtDate(date))
                                .font(.app(9.5))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Step cards

    private func stepCard<Content: View>(index: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .surfaceCard(cornerRadius: 20)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
            .animation(
                .spring(response: 0.45, dampingFraction: 0.85)
                    .delay(0.1 + Double(index) * 0.12),
                value: appeared
            )
    }

    private func stepContent(eyebrow: String, amount: String, amountColor: Color, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)
            Text(amount)
                .font(.app(22, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(amountColor)
            Text(sub)
                .font(.app(11))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
        }
    }

    // MARK: - DCC explainer

    private var dccCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.loss)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(Text(tx.merchantName).fontWeight(.bold)) billed you in \(Derive.homeCurrencyCode) at the terminal — the classic \"pay in \(Derive.homeCurrencyCode)?\" trap.")
                    .font(.app(12))
                    .foregroundStyle(Theme.cream.opacity(0.9))
                    .lineSpacing(3)

                if let localAmount = tx.localAmountEstimated {
                    Text("We reverse-estimated the \(localCurrency) \(fmtForeign(localAmount)) it should have been to catch the real markup.")
                        .font(.app(11.5))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                }

                EstimatedBadge()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.loss.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.loss.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Formatting

    private var differenceTitle: String {
        if tx.markupAmount > 0 { return "THE SKIM" }
        if tx.markupAmount < 0 { return "BETTER THAN REFERENCE" }
        return "NO OBSERVED MARKUP"
    }

    private var differencePercentageLabel: String {
        if markupPct > 0 { return "+\(Derive.fmtPct(markupPct)) over reference" }
        if markupPct < 0 { return "\(Derive.fmtPct(abs(markupPct))) below reference" }
        return "At reference"
    }

    private var differencePrefix: String {
        if tx.markupAmount > 0 { return "−" }
        if tx.markupAmount < 0 { return "+" }
        return ""
    }

    private var differenceColor: Color {
        if tx.markupAmount > 0 { return Theme.loss }
        if tx.markupAmount < 0 { return Theme.good }
        return Theme.muted
    }

    private var referenceRateExplanation: String {
        let base = "1 \(localCurrency) = \(fmtRate(tx.midMarketRate)) \(Derive.homeCurrencyCode)"
        if usesECBReference {
            return "\(base) using the nearest ECB observation on or before this transaction date"
        }
        return "\(base) using Skimmed's offline reference estimate"
    }

    private var methodologyCopy: String {
        if !tx.isForeign {
            return "Domestic charge — excluded from foreign-exchange loss totals and card rankings."
        }
        if !tx.isMarkupCalculable {
            return "Kept for completeness, but excluded from loss totals and card rankings until enough statement evidence is available."
        }
        if usesECBReference {
            return "Compared with the ECB reference rate for the observation date shown."
        }
        return "Compared with an offline reference estimate. Skimmed will update this calculation automatically when verified ECB data is available."
    }

    private var usesECBReference: Bool {
        tx.calculationStatus == .verified && tx.referenceRateSource == .ecb
    }

    /// Rates span 0.00565 (KRW) to 10.2 (GBP) — 4 significant digits keeps
    /// both readable.
    private func fmtRate(_ rate: Double) -> String {
        guard rate > 0 else { return "0" }
        let magnitude = floor(log10(rate))
        let decimals = max(0, Int(3 - magnitude))
        return String(format: "%.\(decimals)f", rate)
    }

    /// Foreign amounts: whole numbers for JPY/KRW-style values, two decimals
    /// otherwise, with thousands separators.
    private func fmtForeign(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        let isWhole = amount.truncatingRemainder(dividingBy: 1) == 0
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = isWhole ? 0 : 2
        return f.string(from: NSNumber(value: amount)) ?? String(amount)
    }
}
