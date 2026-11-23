import Foundation

/// Evidence-backed next-trip playbook for a completed trip audit (Feature 4).
/// Every line carries an `EvidenceLabel`; numbers are only ever Observed
/// (from the user's statements), Published (verified catalogue — none seeded
/// yet, the path degrades honestly), or Estimated (reference-rate-derived).
/// Only cards the user actually imported are recommended.
struct TripAdvice {
    struct Line: Identifiable {
        let id = UUID()
        let icon: String // SF Symbol
        let title: String
        let detail: String
        let label: EvidenceLabel
    }

    let lines: [Line]

    /// Per-card observed performance within one trip's transaction set.
    struct CardPerformance {
        let card: ImportedCard
        let spend: Double // home-currency total
        let markupPct: Double // median signed per-transaction markup
        let confidence: RecommendationConfidence
        let evidenceCount: Int
        let isTiedBest: Bool
    }

    static func build(
        trip: PlannedTrip,
        transactions: [ImportedTransaction],
        cards: [ImportedCard],
        links: [UserCardLink],
        homeCurrency: String,
        formatMoney: (Double) -> String
    ) -> TripAdvice {
        let tripTx = transactions.filter { trip.transactionIDs.contains($0.id) }
        let priced = tripTx.filter { $0.confidence != .unableToCalculate && $0.isForeign }

        guard !priced.isEmpty else {
            return TripAdvice(lines: [Line(
                icon: "questionmark.circle",
                title: "Not enough to go on yet",
                detail: "No priced foreign charges are attached to this trip, so there's nothing to conclude. Add the statements that cover the trip window.",
                label: .insufficient
            )])
        }

        var lines: [Line] = []

        // What went wrong — largest avoidable losses (observed).
        let totalMarkup = NSDecimalNumber(decimal: priced.totalPositiveLoss).doubleValue
        let hasProvisionalLoss = priced.contains { $0.resolvedCalculationStatus != .verified }
        if let worst = priced.max(by: { ($0.markupAmount ?? 0) < ($1.markupAmount ?? 0) }),
           let worstMarkup = worst.markupAmount, worstMarkup > 0 {
            lines.append(Line(
                icon: "flame.fill",
                title: "What went wrong",
                detail: hasProvisionalLoss
                    ? "Using provisional offline reference estimates, this trip's charges carried \(formatMoney(totalMarkup)) of markup. The largest estimate: \(worst.merchantName), \(formatMoney(NSDecimalNumber(decimal: worstMarkup).doubleValue))."
                    : "This trip's charges carried \(formatMoney(totalMarkup)) of markup over the ECB reference rate. The single worst: \(worst.merchantName), \(formatMoney(NSDecimalNumber(decimal: worstMarkup).doubleValue)) above reference.",
                label: hasProvisionalLoss ? .estimated : .observed
            ))
        }

        // Use the same evidence tiers and robust median as the global owned-card
        // recommendation. The destination country was selected by the user;
        // only that explicit country-to-currency mapping drives the advice.
        let destinationCurrency = CurrencyCountry.currency(forCountry: trip.destinationCountry)
        let coreRankings = OwnedCardRankingCore.rank(
            transactions: tripTx,
            ownedCardIDs: Set(cards.map(\.id)),
            destinationCurrencies: Set([destinationCurrency].compactMap { $0 })
        )
        let selectedRanking = destinationCurrency.flatMap { currency in
            coreRankings.first { $0.destinationCurrency == currency }
        }

        let byCard: [CardPerformance] = selectedRanking?.scores.compactMap { score in
            guard let card = cards.first(where: { $0.id == score.cardID }) else { return nil }
            let spend = priced
                .filter {
                    $0.cardID == score.cardID
                        && $0.billedCurrency == destinationCurrency
                }
                .reduce(0.0) { $0 + NSDecimalNumber(decimal: $1.homeCurrencyAmount).doubleValue }
            return CardPerformance(
                card: card,
                spend: spend,
                markupPct: NSDecimalNumber(decimal: score.medianMarkupPct).doubleValue,
                confidence: score.confidence,
                evidenceCount: score.evidenceCount,
                isTiedBest: score.isTiedBest
            )
        } ?? []

        if byCard.count >= 2, let best = byCard.first, let worst = byCard.last {
            let tiedBest = byCard.filter(\.isTiedBest)
            let isCrossCurrency = selectedRanking?.evidenceTier == .verifiedCrossCurrency
            let isProvisional = selectedRanking?.evidenceTier == .provisionalDestination
            let isDirectVerified = selectedRanking?.evidenceTier == .verifiedDestination
            if tiedBest.count == 1 {
                lines.append(Line(
                    icon: "creditcard.fill",
                    title: "Primary card next time: \(best.card.nickname)",
                    detail: isCrossCurrency
                        ? "Limited guide: it had the lowest typical markup across your verified FX history in other currencies."
                        : isProvisional
                            ? "Provisional guide: it had the lowest typical estimated markup on \(destinationCurrency ?? "this currency") using Skimmed's offline reference."
                            : "Its typical observed cost was \(Derive.fmtPct(best.markupPct)) over the ECB reference rate on this trip — your lowest owned card here.",
                    label: isDirectVerified ? .observed : .estimated
                ))
                if byCard.count >= 3 {
                    let backup = byCard[1]
                    lines.append(Line(
                        icon: "creditcard",
                        title: "Backup: \(backup.card.nickname)",
                        detail: isCrossCurrency
                            ? "Second-lowest typical markup across verified FX history elsewhere."
                            : isProvisional
                                ? "Second-lowest typical estimated markup using Skimmed's offline reference."
                                : "Second-lowest typical observed cost at \(Derive.fmtPct(backup.markupPct)) over the ECB reference rate.",
                        label: isDirectVerified ? .observed : .estimated
                    ))
                }
            } else {
                let names = tiedBest.map { $0.card.nickname }.joined(separator: " and ")
                lines.append(Line(
                    icon: "creditcard.fill",
                    title: isCrossCurrency
                        ? "Joint best limited guide: \(names)"
                        : isProvisional ? "Joint best provisional guide: \(names)" : "Joint best observed: \(names)",
                    detail: isCrossCurrency
                        ? "Across verified FX history elsewhere, their typical costs were within 0.05 percentage points. That limited evidence does not support picking one over the other here."
                        : isProvisional
                            ? "Their provisional estimated FX costs were within 0.05 percentage points, so the offline evidence does not support picking one over the other."
                            : "Their typical observed FX costs were within 0.05 percentage points, so the evidence does not support picking one over the other.",
                    label: isDirectVerified ? .observed : .estimated
                ))
            }

            if !worst.isTiedBest && worst.markupPct > best.markupPct {
                lines.append(Line(
                    icon: "hand.raised.fill",
                    title: "Leave \(worst.card.nickname) at home",
                    detail: isCrossCurrency
                        ? "Across verified FX history elsewhere, its typical markup was \(Derive.fmtPct(worst.markupPct - best.markupPct)) higher than your best observed card. Treat this as limited evidence."
                        : isProvisional
                            ? "Using the offline reference estimate, its typical markup was \(Derive.fmtPct(worst.markupPct - best.markupPct)) higher than your provisional best."
                            : "Its typical observed cost was \(Derive.fmtPct(worst.markupPct)) over the ECB reference rate — \(Derive.fmtPct(worst.markupPct - best.markupPct)) more than your best observed card.",
                    label: isDirectVerified ? .observed : .estimated
                ))
                // Conservative savings range: moving HALF to ALL of the worst
                // card's observed spend onto the best card's observed rate.
                let spread = (worst.markupPct - best.markupPct) / 100
                let low = worst.spend * spread * 0.5
                let high = worst.spend * spread
                if isDirectVerified, high >= 1 {
                    lines.append(Line(
                        icon: "arrow.down.right.circle.fill",
                        title: "A similar trip could keep \(formatMoney(low))–\(formatMoney(high))",
                        detail: "If the spend that went on \(worst.card.nickname) went on \(best.card.nickname) instead, at the typical rates observed this trip. Rates vary — treat this as a range, not a promise.",
                        label: .estimated
                    ))
                }
            }
        } else if Set(priced.map(\.cardID)).count < 2 {
            lines.append(Line(
                icon: "creditcard",
                title: "Only one card observed",
                detail: "Add another card's statement from this trip to compare — one card has nothing to rank against.",
                label: .insufficient
            ))
        } else {
            lines.append(Line(
                icon: "creditcard",
                title: "Not enough comparable card evidence",
                detail: "The attached cards do not yet share a comparable verified or provisional evidence tier for this destination.",
                label: .insufficient
            ))
        }

        // DCC: local-currency line (observed only when evidence supports it).
        let dccRows = tripTx.filter(\.isDccSuspected)
        let localCurrencies = Set(priced.filter { $0.billedCurrency != homeCurrency }.map(\.billedCurrency))
        if !dccRows.isEmpty {
            lines.append(Line(
                icon: "text.bubble.fill",
                title: "Always pick the local currency",
                detail: "\(dccRows.count) charge\(dccRows.count == 1 ? "" : "s") on this trip look\(dccRows.count == 1 ? "s" : "") like the \"pay in \(homeCurrency)?\" trap. At terminals and ATMs, choose the local currency every time.",
                label: .observed
            ))
        } else if let currency = localCurrencies.first, localCurrencies.count == 1 {
            lines.append(Line(
                icon: "text.bubble",
                title: "At the terminal, pick \(currency)",
                detail: "No DCC was detected on this trip's statements. If a terminal ever offers \(homeCurrency), decline it — always pay in \(currency).",
                label: .observed
            ))
        }

        // Published catalogue terms — only when a verified figure exists for a
        // confirmed card (none seeded yet; this is the honest-degradation path).
        for perf in byCard {
            guard let institution = CardCatalog.institution(named: perf.card.bank, market: UserDefaults.standard.string(forKey: "profile.homeCountry") ?? HomeRegion.defaultCountry),
                  let link = UserCardLink.match(institutionID: institution.id, last4: perf.card.last4, in: links),
                  let product = CardCatalog.product(id: link.productID),
                  let publishedFee = product.publishedFXFeePct else { continue }
            lines.append(Line(
                icon: "doc.text.fill",
                title: publishedFee == 0
                    ? "\(product.name): no foreign transaction fee (published)"
                    : "\(product.name): \(Derive.fmtPct(publishedFee)) published foreign fee",
                detail: "Issuer-published, verified \(product.lastVerifiedAt ?? "—"). Observed cost on this trip: \(Derive.fmtPct(perf.markupPct)).",
                label: .published
            ))
        }

        return TripAdvice(lines: lines)
    }
}
