import Foundation

/// Statement-import app data model. These types are the persisted, real-mode
/// counterparts of the view-facing types — `AppStore` maps them to the
/// existing view-facing types (`Transaction`, `LinkedAccount`, `Trip`, ...)
/// so views never need to know which mode they're in.

// Additive Codable conformance for the pure ImportCore/Types.swift enum.
extension AccountType: Codable {}

// MARK: - ImportedCard

/// A card/account created via statement import (the real-mode analogue of
/// `LinkedAccount`, but sourced from statements rather than an aggregator).
struct ImportedCard: Codable, Identifiable, Equatable {
    let id: UUID
    var bank: String
    var nickname: String
    var last4: String?
    var accountType: AccountType
    let createdAt: Date
    var lastImportAt: Date?

    init(id: UUID = UUID(), bank: String, nickname: String, last4: String?,
                accountType: AccountType, createdAt: Date = Date(), lastImportAt: Date? = nil) {
        self.id = id
        self.bank = bank
        self.nickname = nickname
        self.last4 = last4
        self.accountType = accountType
        self.createdAt = createdAt
        self.lastImportAt = lastImportAt
    }
}
