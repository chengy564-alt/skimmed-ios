import Foundation

/// ImportCore — persisted column-mapping templates
///
/// When a user manually maps an unrecognised export in MappingView, the
/// confirmed ColumnMapping is saved keyed by bank + header signature, so the
/// next statement with the same shape parses without asking again. One JSON
/// file per template under the store's directory; the key is an FNV-1a hash
/// of the normalized bank name and headers, so header order and punctuation
/// changes ("Amount (HKD)" vs "amount hkd") don't fork templates.
public struct MappingTemplateStore {

    public let directory: URL

    /// Store rooted at an explicit directory — tests point this at a temp
    /// directory; the app can too if it wants templates under its own tree.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Default store under Application Support (created lazily on save).
    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = base.appendingPathComponent("Skimmed/MappingTemplates", isDirectory: true)
    }

    /// Persist a confirmed mapping for this bank + header shape.
    public func save(_ mapping: ColumnMapping, bank: String?, headers: [String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(mapping)
        try data.write(to: fileURL(bank: bank, headers: headers), options: .atomic)
    }

    /// Previously saved mapping for this bank + header shape, or nil.
    /// Deliberately non-throwing: a missing/corrupt template just means the
    /// user maps once more.
    public func load(bank: String?, headers: [String]) -> ColumnMapping? {
        guard let data = try? Data(contentsOf: fileURL(bank: bank, headers: headers)) else { return nil }
        return try? JSONDecoder().decode(ColumnMapping.self, from: data)
    }

    /// Stable template key: normalized bank name + normalized headers.
    public static func key(bank: String?, headers: [String]) -> String {
        let parts = [bank?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""]
            + headers.map(CSVImporter.normalizeHeader)
        return Fingerprint.fnv1aHex(parts.joined(separator: "|"))
    }

    func fileURL(bank: String?, headers: [String]) -> URL {
        directory.appendingPathComponent(Self.key(bank: bank, headers: headers) + ".json")
    }
}
