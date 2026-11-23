import Combine
import Foundation
import StoreKit

/// StoreKit 2 entitlement surface for the Reveal paywall, Settings, and the
/// "Support Skimmed" supporter card. Single source of truth for what the
/// user owns; views read `@Published` state and never talk to StoreKit
/// directly.
///
/// Three products (exact IDs, must match App Store Connect + `Skimmed.storekit`):
///   - `app.skimmed.fullreport` — non-consumable, one-time full report unlock.
///   - `app.skimmed.plus.annual` — auto-renewable subscription (7-day free
///     trial configured as an introductory offer in App Store Connect / the
///     local `.storekit` config, not in code).
///   - `app.skimmed.supporter` — non-consumable, founding-supporter badge.
///
/// Never hard-codes a price anywhere — all display text comes from
/// `Product.displayPrice`/`Product.displayName`. If `Product.products(for:)`
/// returns nothing (no `.storekit` config attached to the scheme, no
/// network, or products not yet propagated in App Store Connect), the
/// paywall degrades to an honest "Purchases unavailable right now" state
/// with a Restore button — it never shows a fake price.
@MainActor
final class EntitlementStore: ObservableObject {
    static let shared = EntitlementStore()

    static let fullReportID = "app.skimmed.fullreport"
    static let plusAnnualID = "app.skimmed.plus.annual"
    static let plusMonthlyID = "app.skimmed.plus.monthly"
    static let supporterID = "app.skimmed.supporter"

    private static let productIDs = [fullReportID, plusAnnualID, plusMonthlyID, supporterID]

    @Published private(set) var products: [Product] = []
    @Published private(set) var unlockedReport = false
    @Published private(set) var isPlus = false
    @Published private(set) var isSupporter = false
    @Published var purchaseInFlight = false
    /// True only when a product load was attempted and came back empty/failed.
    /// Distinct from "not loaded yet" so the paywall can tell "still loading"
    /// from "genuinely unavailable."
    @Published private(set) var loadError = false

    /// Either the one-time unlock or an active Plus subscription grants full
    /// access to the report. Supporter status is separate (a badge, not a
    /// content gate). DEBUG builds honor the developer unlock toggle from
    /// Settings → About — the flag compiles out of release builds entirely.
    var hasFullAccess: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "dev.unlockAll") { return true }
        #endif
        return unlockedReport || isPlus
    }

    var fullReportProduct: Product? { products.first { $0.id == Self.fullReportID } }
    var plusAnnualProduct: Product? { products.first { $0.id == Self.plusAnnualID } }
    var plusMonthlyProduct: Product? { products.first { $0.id == Self.plusMonthlyID } }
    var supporterProduct: Product? { products.first { $0.id == Self.supporterID } }

    enum StoreError: Error {
        case failedVerification
    }

    private var transactionListener: Task<Void, Never>?

    private init() {
        // Listen for transactions that arrive outside an explicit `purchase`
        // call — renewals, family sharing, ask-to-buy approvals, etc.
        transactionListener = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshCurrentEntitlements()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Loading

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { lhs, rhs in
                let lhsIndex = Self.productIDs.firstIndex(of: lhs.id) ?? Int.max
                let rhsIndex = Self.productIDs.firstIndex(of: rhs.id) ?? Int.max
                return lhsIndex < rhsIndex
            }
            loadError = loaded.isEmpty
        } catch {
            products = []
            loadError = true
        }
    }

    // MARK: - Purchasing

    func purchase(_ product: Product) async throws {
        purchaseInFlight = true
        defer { purchaseInFlight = false }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try Self.checkVerified(verification)
            await apply(transaction)
            await transaction.finish()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restore() async {
        // Re-syncs local receipt/transaction state with App Store servers,
        // then re-derives entitlements from `Transaction.currentEntitlements`.
        try? await StoreKit.AppStore.sync()
        await refreshCurrentEntitlements()
    }

    // MARK: - Entitlement sweep

    /// Walks every transaction the device currently holds and re-derives the
    /// three published flags from scratch — the source of truth after
    /// restore, app launch, or an out-of-band transaction update.
    func refreshCurrentEntitlements() async {
        var unlockedReport = false
        var isPlus = false
        var isSupporter = false

        for await result in StoreKit.Transaction.currentEntitlements {
            guard let transaction = try? Self.checkVerified(result), transaction.revocationDate == nil else {
                continue
            }
            switch transaction.productID {
            case Self.fullReportID: unlockedReport = true
            case Self.plusAnnualID, Self.plusMonthlyID: isPlus = true
            case Self.supporterID: isSupporter = true
            default: break
            }
        }

        self.unlockedReport = unlockedReport
        self.isPlus = isPlus
        self.isSupporter = isSupporter
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard let transaction = try? Self.checkVerified(result) else { return }
        await apply(transaction)
        await transaction.finish()
    }

    private func apply(_ transaction: StoreKit.Transaction) async {
        guard transaction.revocationDate == nil else {
            await refreshCurrentEntitlements()
            return
        }
        switch transaction.productID {
        case Self.fullReportID: unlockedReport = true
        case Self.plusAnnualID, Self.plusMonthlyID: isPlus = true
        case Self.supporterID: isSupporter = true
        default: break
        }
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified: throw StoreError.failedVerification
        case .verified(let safe): return safe
        }
    }
}
