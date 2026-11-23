import SwiftUI
import UniformTypeIdentifiers

/// "+ ADD" pill — the persistent way to import another statement. Sits
/// beside the count pill in the Cards/Trips headers; every extra statement
/// merges into the same report — duplicates skipped, trips stitched across
/// months.
struct AddStatementPill: View {
    @State private var showImport = false

    var body: some View {
        Button { showImport = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("ADD")
                    .font(.app(9.5, weight: .bold))
                    .kerning(0.5)
            }
            .foregroundStyle(Theme.accent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.accent.opacity(0.15), in: Capsule())
            // Real 44pt hit target (pill is ~24pt tall on its own).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .fullScreenCover(isPresented: $showImport) {
            ImportEntrySheet { showImport = false }
        }
    }
}

/// Minimal, compact statement-import entry point reachable from anywhere in
/// the app (not just onboarding) — same upload copy/behavior as
/// `OnboardingView`'s `ImportScreen`, without the waitlist/support cards
/// (those stay onboarding-only).
struct ImportEntrySheet: View {
    var onDone: () -> Void

    private struct PickedFile: Identifiable {
        let id = UUID()
        let data: Data
        let filename: String
    }

    @ObservedObject private var appStore = AppStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isImporterPresented = false
    @State private var pickedFile: PickedFile? = nil
    @State private var pickError: String? = nil
    /// Statements analysed since this sheet opened — flips the UI into the
    /// "added ✓ · add another / done" state. The paywall/reveal is NEVER
    /// shown here: it belongs to onboarding only, so returning users can add
    /// statements as often as they like without being re-pitched.
    @State private var addedThisSession = 0

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(alignment: .leading, spacing: 0) {
                header

                if addedThisSession > 0 {
                    summaryCard
                    if let pickError { errorLine(pickError) }
                    Spacer()
                    PrimaryButton(title: "Done", trailingIcon: nil, action: onDone)
                    Button {
                        isImporterPresented = true
                    } label: {
                        Text("Add another statement")
                            .font(.app(12.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                } else {
                    uploadCard
                    Spacer()
                }
            }
            .padding(20)
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
                    pickedFile = PickedFile(data: data, filename: url.lastPathComponent)
                } catch {
                    pickError = "Couldn't read that file — try another one."
                }
            case .failure:
                pickError = "Couldn't read that file — try another one."
            }
        }
        .fullScreenCover(item: $pickedFile) { file in
            // Straight to the pipeline — no reveal/paywall. Onboarding owns
            // that moment; in-app imports just analyse and return.
            ImportFlowView(
                fileData: file.data,
                filename: file.filename,
                onAnalyzed: {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.85)) {
                        addedThisSession += 1
                    }
                    pickedFile = nil
                },
                onCancel: { pickedFile = nil }
            )
        }
    }

    private var header: some View {
        HStack {
            Text(addedThisSession > 0 ? "Statements added" : "Import a statement")
                .font(.app(18, weight: .heavy))
                .foregroundStyle(Theme.cream)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.cream)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.06), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(PressStyle(scale: 0.9))
        }
        .padding(.bottom, 20)
    }

    private var uploadCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Upload a bank statement")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Theme.cream)
            Text("Your statement is analysed on this device. Skimmed does not store your raw statement file. Add as many cards and months as you like.")
                .font(.app(12.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 10)

            if let pickError { errorLine(pickError) }

            PrimaryButton(title: "Choose a statement", leadingIcon: "lock.fill", trailingIcon: nil) {
                isImporterPresented = true
            }
            .padding(.top, 18)
        }
        .padding(20)
        .surfaceCard()
    }

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.good)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(addedThisSession) statement\(addedThisSession == 1 ? "" : "s") analysed")
                    .font(.app(14, weight: .bold))
                    .foregroundStyle(Theme.cream)
                Text("\(appStore.cards.count) card\(appStore.cards.count == 1 ? "" : "s") · \(appStore.importedTransactions.count) charge\(appStore.importedTransactions.count == 1 ? "" : "s") on file. Add another, or you're done.")
                    .font(.app(11.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .glass(cornerRadius: 20)
    }

    private func errorLine(_ message: String) -> some View {
        Text(message)
            .font(.app(11.5, weight: .semibold))
            .foregroundStyle(Theme.loss)
            .padding(.top, 10)
    }
}
