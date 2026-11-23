import SwiftUI

/// Small brand-colored bank monogram tile — used in the onboarding bank grid
/// and next to linked-card names. Colors approximate each institution's brand
/// palette, lifted slightly so they read against the dark surfaces. Swap in
/// real logo assets later without touching call sites.
struct BankMark: View {
    let bank: String
    var size: CGFloat = 28

    private struct Brand {
        let mark: String
        let color: Color
    }

    /// Keyed by the short institution names used in `RegionConfig.bankGrid`
    /// and `LinkedAccount.institutionName`; unknown banks fall back to a
    /// monogram tile below.
    private static let brands: [String: Brand] = [
        "HSBC": Brand(mark: "HSBC", color: Color(hex: "#F23F49")),
        "Hang Seng": Brand(mark: "HS", color: Color(hex: "#35B688")),
        "SC": Brand(mark: "SC", color: Color(hex: "#3FA0FF")),
        "BOC": Brand(mark: "BOC", color: Color(hex: "#E8556B")),
        "BEA": Brand(mark: "BEA", color: Color(hex: "#4D8FDB")),
        "DBS": Brand(mark: "DBS", color: Color(hex: "#FF5C45")),
    ]

    private var brand: Brand {
        Self.brands[bank]
            ?? Brand(mark: String(bank.prefix(2)).uppercased(), color: Theme.accent)
    }

    /// The institution's brand color — used by CardsView to build full
    /// card-face artwork from the same palette as the monogram tiles.
    static func brandColor(for bank: String) -> Color {
        brands[bank]?.color ?? Theme.accent
    }

    var body: some View {
        Text(brand.mark)
            .font(.app(size * 0.32, weight: .heavy))
            .kerning(0.3)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(brand.color)
            .padding(.horizontal, 3)
            .frame(width: size, height: size)
            .background(brand.color.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(brand.color.opacity(0.35), lineWidth: 1))
    }
}
