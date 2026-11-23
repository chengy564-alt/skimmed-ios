import Foundation

/// ImportCore — pure validation rules for the free automatic-connection
/// waitlist form (B7). Kept Foundation-only and side-effect-free so
/// `swift test` can exercise the real rules the app-side `WaitlistService`
/// and `WaitlistSheet` both rely on — no networking, no persistence here.
public enum WaitlistValidation {

    /// Deliberately simple `local@domain.tld` shape check — matches what the
    /// onboarding sheet already validated pre-B7, not a full RFC 5322 parser
    /// (which would reject plenty of real addresses and isn't worth the
    /// complexity for a "notify me" form).
    public static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^\S+@\S+\.\S+$"#, options: .regularExpression) != nil
    }

    /// Non-empty after trimming — used for country and bank, the two other
    /// required fields (note is optional and never validated).
    public static func isNonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The full gate the service re-checks defensively before submitting,
    /// independent of whatever the sheet's own `isValid` computed — a
    /// second, cheap line of defense against a future UI bug letting garbage
    /// through.
    public static func isValidEntry(email: String, country: String, bank: String) -> Bool {
        isValidEmail(email) && isNonEmpty(country) && isNonEmpty(bank)
    }
}
