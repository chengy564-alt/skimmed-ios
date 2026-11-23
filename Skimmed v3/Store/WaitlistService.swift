import Foundation

/// Real submitter for the free automatic-connection waitlist (B7), conforming
/// to the `WaitlistSubmitting` seam `WaitlistSheet` was already built against
/// in B4/B6 (see `OnboardingView.swift`). Replaces `StubWaitlistSubmitter`.
///
/// One entry is cached locally regardless of which path below runs, so
/// Profile can show "you're on the waitlist for {bank}" and let the user
/// edit/resubmit or leave — this is the only local persistence the free
/// waitlist needs; there is no server-side account to sync against.
struct WaitlistEntry: Codable, Equatable {
    var email: String
    var country: String
    var bank: String
    var accountType: AccountType
    var note: String
    var submittedAt: Date
}

enum WaitlistError: Error {
    case invalidInput
    case network(Error)
    case server(status: Int)

    /// Friendly, non-technical copy — `WaitlistSheet.submit()` catches
    /// whatever `WaitlistSubmitting.submit` throws and shows a flat
    /// "Something went wrong — try again." either way, so this is mostly
    /// documentation of *why* for anyone debugging, not user-facing text.
    var friendlyMessage: String {
        switch self {
        case .invalidInput: return "Please check your details and try again."
        case .network: return "Couldn't reach the server — check your connection and try again."
        case .server: return "Something went wrong on our end — try again."
        }
    }
}

final class WaitlistService: WaitlistSubmitting {

    /// Info.plist key (falls back to an environment variable of the same
    /// name) that, if set, points at a real waitlist intake endpoint. Neither
    /// is configured yet — the app currently always takes the mock path.
    /// Whoever stands up the backend adds `SKIMMED_WAITLIST_URL` to the
    /// target's Info.plist (a plain HTTPS URL string, not a secret — the
    /// endpoint accepts unauthenticated POSTs of non-sensitive interest-list
    /// data) and the real path activates with no code change.
    private static let endpointInfoKey = "SKIMMED_WAITLIST_URL"

    private static var configuredEndpoint: URL? {
        let raw = Bundle.main.object(forInfoDictionaryKey: endpointInfoKey) as? String
            ?? ProcessInfo.processInfo.environment[endpointInfoKey]
        guard let raw, !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return url
    }

    private let persistence: Persistence
    private let session: URLSession

    init(persistence: Persistence = Persistence(), session: URLSession = .shared) {
        self.persistence = persistence
        self.session = session
    }

    func submit(email: String, country: String, bank: String, accountType: AccountType, note: String?) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCountry = country.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBank = bank.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Defensive re-check — the sheet already validates, but the service
        // never trusts a caller to have done so.
        guard WaitlistValidation.isValidEntry(email: trimmedEmail, country: trimmedCountry, bank: trimmedBank) else {
            throw WaitlistError.invalidInput
        }

        let entry = WaitlistEntry(
            email: trimmedEmail, country: trimmedCountry, bank: trimmedBank,
            accountType: accountType, note: trimmedNote, submittedAt: Date()
        )

        if let endpoint = Self.configuredEndpoint {
            try await submitRemote(entry, to: endpoint)
        } else {
            try await submitMock(entry)
        }

        Self.cache(entry, persistence: persistence)
    }

    // MARK: - Real path

    private func submitRemote(_ entry: WaitlistEntry, to endpoint: URL) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "email": entry.email,
            "country": entry.country,
            "bank": entry.bank,
            "account_type": entry.accountType.rawValue,
            "note": entry.note,
            "submitted_at": ISO8601DateFormatter().string(from: entry.submittedAt),
            "app": "skimmed-ios",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw WaitlistError.network(error)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WaitlistError.server(status: status)
        }
    }

    // MARK: - Mock path (development only — no endpoint configured)

    /// No backend has been provided yet, so every build today takes this
    /// path: the entry is written to local Application Support (same
    /// convention as `Persistence`, see B3) and the call succeeds after a
    /// short delay to mirror real network latency in the UI. Nothing is
    /// transmitted anywhere; no secrets are involved.
    private func submitMock(_ entry: WaitlistEntry) async throws {
        try await Task.sleep(nanoseconds: 900_000_000)
    }

    // MARK: - Local cache (both paths use this, so Profile can read it back)

    private static func cache(_ entry: WaitlistEntry, persistence: Persistence) {
        persistence.saveWaitlistEntry(entry)
    }

    /// The most recently submitted waitlist entry, if any — nil once the
    /// user has never joined or has left the waitlist via Profile.
    static func lastSubmission(persistence: Persistence = Persistence()) -> WaitlistEntry? {
        persistence.loadWaitlistEntry()
    }

    /// Called from Profile's "Leave waitlist" destructive action.
    static func clearSubmission(persistence: Persistence = Persistence()) {
        persistence.clearWaitlistEntry()
    }
}
