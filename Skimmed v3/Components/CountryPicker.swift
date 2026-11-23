import SwiftUI

/// Every ISO 3166 country, for the "usual destinations" pickers — code +
/// localized English name, sorted A–Z. Flags come from `Derive.flag`.
enum CountryCatalog {
    static let all: [(code: String, name: String)] = {
        let en = Locale(identifier: "en_US")
        return Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
            .compactMap { code -> (code: String, name: String)? in
                guard let name = en.localizedString(forRegionCode: code) else { return nil }
                return (code, name)
            }
            .sorted { $0.name < $1.name }
    }()

    static func name(for code: String) -> String {
        Locale(identifier: "en_US").localizedString(forRegionCode: code.uppercased()) ?? code
    }
}

/// Liquid-glass "dropdown bar" that opens a searchable multi-select over
/// every country. Binds to a `Set` of ISO alpha-2 codes. Used by onboarding
/// and Settings for "usual destinations" — no more short fixed chip list.
struct CountrySelectField: View {
    @Binding var selection: Set<String>
    var placeholder: String = "Select countries"

    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selection.isEmpty ? Theme.muted : Theme.accent)

                if selection.isEmpty {
                    Text(placeholder)
                        .font(.app(13.5))
                        .foregroundStyle(Theme.muted)
                } else {
                    Text(summary)
                        .font(.app(13.5, weight: .semibold))
                        .foregroundStyle(Theme.cream)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .glass(cornerRadius: 16)
            // The whole bar is the hit target — including the empty gap
            // between the label and the chevron, not just the glyphs.
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .sheet(isPresented: $showPicker) {
            CountryPickerSheet(selection: $selection)
        }
    }

    private var summary: String {
        let names = CountryCatalog.all
            .filter { selection.contains($0.code) }
            .map { "\(Derive.flag($0.code)) \($0.name)" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return names.prefix(1).joined() + "  +\(names.count - 1) more"
    }
}

/// The searchable multi-select sheet itself — every country as a glass row
/// with flag, name, and a check. Search filters by name or code.
struct CountryPickerSheet: View {
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [(code: String, name: String)] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return CountryCatalog.all }
        return CountryCatalog.all.filter {
            $0.name.lowercased().contains(q) || $0.code.lowercased() == q
        }
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Where do you usually go?")
                        .font(.app(18, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                    Spacer()
                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.app(13, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(PressStyle(scale: 0.92))
                }
                .padding(.bottom, 14)

                searchField

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered, id: \.code) { country in
                            row(country)
                        }
                        if filtered.isEmpty {
                            Text("No matches — try the country's English name.")
                                .font(.app(12))
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
            }
            .padding(20)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var searchField: some View {
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
        .padding(.vertical, 12)
        .glass(cornerRadius: 14)
    }

    private func row(_ country: (code: String, name: String)) -> some View {
        let isOn = selection.contains(country.code)
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                if isOn { selection.remove(country.code) } else { selection.insert(country.code) }
            }
        } label: {
            HStack(spacing: 12) {
                Text(Derive.flag(country.code))
                    .font(.system(size: 22))
                Text(country.name)
                    .font(.app(14, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.accent : Theme.muted.opacity(0.5))
                    .scaleEffect(isOn ? 1.06 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isOn ? Theme.accent.opacity(0.1) : Theme.surface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOn ? Theme.accent.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .sensoryFeedback(.selection, trigger: isOn)
    }
}
