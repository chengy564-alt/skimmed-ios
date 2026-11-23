import Foundation

/// JSON persistence for real-mode data, in
/// `~/Library/Application Support/Skimmed/` with complete file protection.
/// Writes are atomic (write-to-temp-then-replace via `Data.write(options:
/// .atomic)`), so a crash mid-write never corrupts the previous good file.
///
/// Raw statement files are never written here — only the already-parsed,
/// already-analyzed `ImportedCard`/`ImportedTransaction` records and the
/// `MappingTemplateStore` pass-through (B1's column-mapping templates, which
/// contain no transaction data, just column indexes keyed by bank+headers).
struct Persistence {
    private let directory: URL
    private let cardsFile: URL
    private let transactionsFile: URL
    private let waitlistFile: URL
    private let plannedTripsFile: URL
    private let userCardLinksFile: URL

    /// Injectable directory for tests; defaults to Application Support/Skimmed.
    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        self.directory = dir
        self.cardsFile = dir.appendingPathComponent("cards.json")
        self.transactionsFile = dir.appendingPathComponent("transactions.json")
        self.waitlistFile = dir.appendingPathComponent("waitlist.json")
        self.plannedTripsFile = dir.appendingPathComponent("plannedtrips.json")
        self.userCardLinksFile = dir.appendingPathComponent("usercards.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Skimmed", isDirectory: true)
    }

    /// The mapping-template store lives in a subdirectory of the same
    /// Application Support root, so it moves with the rest of real-mode
    /// data on delete-all. Pass-through to B1's `MappingTemplateStore`.
    var mappingTemplateStore: MappingTemplateStore {
        MappingTemplateStore(directory: directory.appendingPathComponent("MappingTemplates", isDirectory: true))
    }

    /// Public ECB observations are cached separately from private imported
    /// data. Erasing statements does not need to redownload the same public
    /// historical rates later.
    var historicalRateCacheURL: URL {
        directory.appendingPathComponent("ecb-rates.json")
    }

    // MARK: - cards

    func loadCards() -> [ImportedCard] {
        load(from: cardsFile) ?? []
    }

    func saveCards(_ cards: [ImportedCard]) {
        save(cards, to: cardsFile)
    }

    // MARK: - transactions

    func loadTransactions() -> [ImportedTransaction] {
        load(from: transactionsFile) ?? []
    }

    func saveTransactions(_ transactions: [ImportedTransaction]) {
        save(transactions, to: transactionsFile)
    }

    // MARK: - waitlist (B7 — free automatic-connection waitlist, one cached entry)

    func loadWaitlistEntry() -> WaitlistEntry? {
        load(from: waitlistFile)
    }

    func saveWaitlistEntry(_ entry: WaitlistEntry) {
        save(entry, to: waitlistFile)
    }

    func clearWaitlistEntry() {
        try? FileManager.default.removeItem(at: waitlistFile)
    }

    // MARK: - planned trips + card links (v1.1 trip audits / catalogue)
    // Migration path: both files simply don't exist for pre-v1.1 installs —
    // loads return [] and nothing else changes.

    func loadPlannedTrips() -> [PlannedTrip] {
        load(from: plannedTripsFile) ?? []
    }

    func savePlannedTrips(_ trips: [PlannedTrip]) {
        save(trips, to: plannedTripsFile)
    }

    func loadUserCardLinks() -> [UserCardLink] {
        load(from: userCardLinksFile) ?? []
    }

    func saveUserCardLinks(_ links: [UserCardLink]) {
        save(links, to: userCardLinksFile)
    }

    // MARK: - deletion

    /// Deletes one card and every transaction that references it (persists
    /// the pruned arrays). Returns the pruned arrays so the caller (AppStore)
    /// can update its in-memory state without a second load round-trip.
    func deleteCard(id: UUID, cards: [ImportedCard], transactions: [ImportedTransaction]) -> (cards: [ImportedCard], transactions: [ImportedTransaction]) {
        let prunedCards = cards.filter { $0.id != id }
        let prunedTx = transactions.filter { $0.cardID != id }
        saveCards(prunedCards)
        saveTransactions(prunedTx)
        return (prunedCards, prunedTx)
    }

    /// Wipes all real-mode data: cards, transactions, and mapping templates.
    /// Never deletes anything outside the `Skimmed` Application Support
    /// subdirectory.
    func deleteAllImportedData() {
        try? FileManager.default.removeItem(at: cardsFile)
        try? FileManager.default.removeItem(at: transactionsFile)
        try? FileManager.default.removeItem(at: plannedTripsFile)
        try? FileManager.default.removeItem(at: userCardLinksFile)
        let templatesDir = directory.appendingPathComponent("MappingTemplates", isDirectory: true)
        try? FileManager.default.removeItem(at: templatesDir)
    }

    // MARK: - generic JSON helpers

    private func load<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.skimmedImport.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder.skimmedImport.encode(value) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            // Best-effort: a failed write leaves the previous good file in place
            // (atomic write never partially overwrites), so real-mode data can't
            // be corrupted by a failed persist.
        }
    }
}

extension JSONEncoder {
    static let skimmedImport: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let skimmedImport: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
