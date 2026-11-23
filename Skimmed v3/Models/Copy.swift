import Foundation

/// Screen copy per region config, verbatim from the approved screen spec
/// (ported from the reference prototype's `lib/copy.ts`).
/// The prototype renders `hkd`; usd/gbp are included because the spec defines
/// them — adding a region should never mean editing a screen.

struct ReceiptLine {
    let label: String
    let amount: String
}

struct Benefit {
    let bold: String
    let rest: String
}

struct FreqChip {
    let value: TripFreqBucket
    let label: String
}

struct RegionCopy {
    let destinationCity: String
    let receiptMerchant: String
    let receiptLines: [ReceiptLine]
    let receiptBilled: String // glows red
    let receiptShould: String // slides in
    let s1Headline: String
    let s1Subhead: String
    let s1Button: String
    let s2Headline: String
    let s2Benefits: [Benefit]
    let s2Button: String
    let s3Q1: String
    let s3FreqChips: [FreqChip]
    let s3Q2: String
    let s3bHeadline: String
    let s3bSubhead: String
    let s3bButton: String
    let s3bSkip: String
    let s4Headline: String
    let s4ScanTemplate: String // "Reading {m} months of transactions… found {n} foreign charges"
    let s4ProofRow: [String]
    let s4Button: String
    let revealHeadlineSuffix: String // after the big number
    let revealSubline: String
    let revealMethodology: String

    /// Identical across all launch regions.
    func revealEyebrow(_ txCount: Int) -> String {
        "Last 12 months, across your \(txCount) foreign transactions:"
    }

    func scanLine(found: Int, months: Int) -> String {
        s4ScanTemplate
            .replacingOccurrences(of: "{n}", with: String(found))
            .replacingOccurrences(of: "{m}", with: String(months))
    }
}

enum Copy {

    /// Resolves from the user's chosen home country — USD copy is the
    /// default (and the generic-English fallback for markets without their
    /// own copy set). Views read this at init, after the home question.
    static var active: RegionCopy { regionCopy[RegionId.active]! }

    static let regionCopy: [RegionId: RegionCopy] = [
        .hkd: RegionCopy(
            destinationCity: "Bangkok",
            receiptMerchant: "THIP SAMAI — BANGKOK",
            receiptLines: [
                ReceiptLine(label: "Pad Thai (crab) ×2", amount: "1,240.00"),
                ReceiptLine(label: "Coconut ice cream", amount: "360.00"),
                ReceiptLine(label: "Service 10%", amount: "160.00"),
            ],
            receiptBilled: "HKD 428.50",
            receiptShould: "should have been HKD 401.20",
            s1Headline: "Your bank charged you twice for that pad thai.",
            s1Subhead: "Every time you tap your card abroad, your bank marks up the real exchange rate — and it never shows up as a 'fee' on your statement.",
            s1Button: "Show me what I've been losing",
            s2Headline: "Skimmed reads your statements so you don't have to.",
            s2Benefits: [
                Benefit(bold: "Find the leak.", rest: " We use a date-matched ECB reference when available; offline estimates are labelled and update automatically."),
                Benefit(bold: "Catch every trip.", rest: " Upload a statement and we flag the rip-off charges — including the 'pay in HKD?' trap at the card terminal."),
                Benefit(bold: "Plug it in one tap.", rest: " We tell you exactly which of your cards to use in each country, ranked by real cost."),
            ],
            s2Button: "Sounds good — keep going",
            s3Q1: "How many trips outside Hong Kong in the last 12 months?",
            s3FreqChips: [
                FreqChip(value: .one, label: "1 trip a year"),
                FreqChip(value: .two, label: "2 trips a year"),
                FreqChip(value: .three, label: "3 trips a year"),
                FreqChip(value: .four, label: "4 trips a year"),
                FreqChip(value: .tenPlus, label: "10+ trips a year"),
                FreqChip(value: .airports, label: "I basically live in airports"),
            ],
            s3Q2: "Where do you usually go?",
            s3bHeadline: "Now, let's look at the actual damage.",
            s3bSubhead: "Upload a statement from the card you travel with. CSV works best — most banks export one in two taps. Everything is analysed on this device; Skimmed never uploads your raw statement.",
            s3bButton: "Choose a statement",
            s3bSkip: "Skip for now",
            s4Headline: "This isn't a guess. It's arithmetic.",
            s4ScanTemplate: "Reading {m} months of transactions… found {n} foreign charges",
            s4ProofRow: [
                "Free ECB daily rates · labelled offline fallback",
                "On-device analysis",
                "Read-only. Bank-grade encryption.",
            ],
            s4Button: "See my number",
            revealHeadlineSuffix: "to hidden exchange-rate markups.",
            revealSubline: "That's a flight to Bangkok. Gone. Every year.",
            revealMethodology: "Uses a date-matched ECB reference when available; offline estimates are labelled and update automatically. Tap any line to see the math."
        ),
        .usd: RegionCopy(
            destinationCity: "Mexico City",
            receiptMerchant: "TAQUERÍA ORINOCO — CDMX",
            receiptLines: [
                ReceiptLine(label: "Tacos al pastor ×6", amount: "540.00"),
                ReceiptLine(label: "Agua de horchata", amount: "95.00"),
                ReceiptLine(label: "Propina 10%", amount: "63.00"),
            ],
            receiptBilled: "USD 42.80",
            receiptShould: "should have been USD 40.10",
            s1Headline: "Your bank charged you twice for those tacos.",
            s1Subhead: "Every time you swipe abroad, you pay twice: a foreign transaction fee buried in your card agreement, and a markup baked into the rate. Neither ever gets totaled up for you.",
            s1Button: "Show me what I've been losing",
            s2Headline: "Skimmed reads your statements so you don't have to.",
            s2Benefits: [
                Benefit(bold: "Find the leak.", rest: " We use a date-matched ECB reference when available; offline estimates are labelled and update automatically."),
                Benefit(bold: "Catch every trip.", rest: " Upload a statement and we flag the rip-off charges — including the 'pay in USD?' trap at the card terminal."),
                Benefit(bold: "Plug it in one tap.", rest: " We tell you exactly which of your cards to use in each country, ranked by real cost."),
            ],
            s2Button: "Sounds good — keep going",
            s3Q1: "How many trips outside the US in the last 12 months?",
            s3FreqChips: [
                FreqChip(value: .one, label: "1 trip a year"),
                FreqChip(value: .two, label: "2 trips a year"),
                FreqChip(value: .three, label: "3 trips a year"),
                FreqChip(value: .four, label: "4 trips a year"),
                FreqChip(value: .tenPlus, label: "10+ trips a year"),
                FreqChip(value: .airports, label: "I basically live in airports"),
            ],
            s3Q2: "Where do you usually go?",
            s3bHeadline: "Now, let's look at the actual damage.",
            s3bSubhead: "Upload a statement from the card you travel with. CSV works best — most banks let you export one in two taps. Everything is analysed on this device; Skimmed never uploads your raw statement.",
            s3bButton: "Choose a statement",
            s3bSkip: "Skip for now",
            s4Headline: "This isn't a guess. It's arithmetic.",
            s4ScanTemplate: "Reading {m} months of transactions… found {n} foreign charges",
            s4ProofRow: [
                "Free ECB daily rates · labelled offline fallback",
                "On-device analysis",
                "Read-only. Bank-grade encryption.",
            ],
            s4Button: "See my number",
            revealHeadlineSuffix: "to foreign transaction fees and hidden markups.",
            revealSubline: "That's a round trip to Cancún. Gone. Every year.",
            revealMethodology: "Uses a date-matched ECB reference when available; offline estimates are labelled and update automatically. Tap any line to see the math."
        ),
        .gbp: RegionCopy(
            destinationCity: "Barcelona",
            receiptMerchant: "CAN SOLÉ — BARCELONA",
            receiptLines: [
                ReceiptLine(label: "Paella de marisco ×2", amount: "52.00"),
                ReceiptLine(label: "Estrella Damm ×2", amount: "9.40"),
                ReceiptLine(label: "Servicio", amount: "6.10"),
            ],
            receiptBilled: "GBP 68.40",
            receiptShould: "should have been GBP 64.30",
            s1Headline: "Your bank charged you twice for that paella.",
            s1Subhead: "Every time you tap your card abroad, your bank adds a non-sterling fee and marks up the exchange rate — and you'd have to open a PDF on their website to find out how much.",
            s1Button: "Show me what I've been losing",
            s2Headline: "Skimmed reads your statements so you don't have to.",
            s2Benefits: [
                Benefit(bold: "Find the leak.", rest: " We use a date-matched ECB reference when available; offline estimates are labelled and update automatically."),
                Benefit(bold: "Catch every trip.", rest: " Upload a statement and we flag the rip-off charges — including the 'pay in GBP?' trap at the card terminal."),
                Benefit(bold: "Plug it in one tap.", rest: " We tell you exactly which of your cards to use in each country, ranked by real cost."),
            ],
            s2Button: "Sounds good — keep going",
            s3Q1: "How many trips outside the UK in the last 12 months?",
            s3FreqChips: [
                FreqChip(value: .one, label: "1 trip a year"),
                FreqChip(value: .two, label: "2 trips a year"),
                FreqChip(value: .three, label: "3 trips a year"),
                FreqChip(value: .four, label: "4 trips a year"),
                FreqChip(value: .tenPlus, label: "10+ trips a year"),
                FreqChip(value: .airports, label: "I basically live in airports"),
            ],
            s3Q2: "Where do you usually go?",
            s3bHeadline: "Now, let's look at the actual damage.",
            s3bSubhead: "Upload a statement from the card you travel with. CSV works best — most banks let you export one in two taps. Everything is analysed on this device; Skimmed never uploads your raw statement.",
            s3bButton: "Choose a statement",
            s3bSkip: "Skip for now",
            s4Headline: "This isn't a guess. It's arithmetic.",
            s4ScanTemplate: "Reading {m} months of transactions… found {n} foreign charges",
            s4ProofRow: [
                "Free ECB daily rates · labelled offline fallback",
                "On-device analysis",
                "Read-only. Bank-grade encryption.",
            ],
            s4Button: "See my number",
            revealHeadlineSuffix: "to non-sterling fees and hidden markups.",
            revealSubline: "That's a return flight to Barcelona. Gone. Every year.",
            revealMethodology: "Uses a date-matched ECB reference when available; offline estimates are labelled and update automatically. Tap any line to see the math."
        ),
    ]
}
