import Foundation

/// ImportCore — Statement-import data model
///
/// Pure Foundation. These types are shared between the app target (compiled
/// directly via the synced group) and the SPM `ImportCore` module used by
/// `swift test`, so nothing here may import SwiftUI/UIKit or reference app
/// types (Transaction, Trip, LinkedAccount are taken by Types.swift).

// MARK: - parsed_transaction

/// One normalized transaction row from an imported statement.
///
/// Sign convention (load-bearing for the analyzer): `amount` is the settled
/// figure in the statement currency, POSITIVE for money out (purchases,
/// fees), NEGATIVE for money in (refunds, repayments). Bank exports that use
/// money-out-negative signed columns are flipped at parse time; debit/credit
/// column pairs map debit → positive, credit → negative. `originalAmount`
/// carries the same sign as `amount`.
public struct ParsedTransaction: Equatable {
    public let date: Date
    public let description: String
    public let amount: Decimal
    public let currency: String? // ISO 4217 when a per-row currency column exists
    public let originalAmount: Decimal? // pre-conversion amount, when the bank exports it
    public let originalCurrency: String? // ISO 4217 of `originalAmount`
    public let cardLast4: String? // last 4 digits from a card-number column, if any
    public let rawLine: String // the source CSV record, verbatim — kept for warnings UI, never persisted

    public init(date: Date, description: String, amount: Decimal, currency: String?,
                originalAmount: Decimal?, originalCurrency: String?, cardLast4: String?,
                rawLine: String) {
        self.date = date
        self.description = description
        self.amount = amount
        self.currency = currency
        self.originalAmount = originalAmount
        self.originalCurrency = originalCurrency
        self.cardLast4 = cardLast4
        self.rawLine = rawLine
    }
}

// MARK: - parsed_statement

/// A whole parsed statement plus everything the import UI needs to confirm
/// it with the user (bank guess input, card match input, non-fatal warnings).
public struct ParsedStatement {
    public let bankHint: String? // bank name found in the file body or filename; input to BankDetector
    public let accountLast4: String? // statement-level last 4 (uniform card column or preamble text)
    public let statementCurrency: String? // uniform per-row currency, or code lifted from an "Amount (XXX)" header
    public let period: ClosedRange<Date>? // min...max transaction date
    public let transactions: [ParsedTransaction]
    public let warnings: [String] // skipped rows, ambiguity assumptions — surfaced in PreviewImportView

    public init(bankHint: String?, accountLast4: String?, statementCurrency: String?,
                period: ClosedRange<Date>?, transactions: [ParsedTransaction], warnings: [String]) {
        self.bankHint = bankHint
        self.accountLast4 = accountLast4
        self.statementCurrency = statementCurrency
        self.period = period
        self.transactions = transactions
        self.warnings = warnings
    }
}

// MARK: - import_error

/// Import failures the UI must handle distinctly: `unreadable` → honest
/// "export a CSV instead" message, `empty` → nothing to analyse,
/// `needsMapping` → MappingView with the real headers + sample rows.
public enum ImportError: Error, Equatable {
    case unreadable
    case empty
    case needsMapping(headers: [String], sampleRows: [[String]])
}

// MARK: - column_mapping

/// User- or template-supplied column assignment. All fields are column
/// indexes into the header row; `dateFormat` (DateFormatter pattern)
/// overrides automatic date-format inference when set. Codable so
/// MappingTemplateStore can persist confirmed mappings per bank+header set.
public struct ColumnMapping: Codable, Equatable {
    public var date: Int?
    public var description: Int?
    public var amount: Int? // single signed column — mutually reinforcing with debit/credit below
    public var debit: Int? // money out (becomes positive `amount`)
    public var credit: Int? // money in (becomes negative `amount`)
    public var currency: Int?
    public var originalAmount: Int?
    public var originalCurrency: Int?
    public var cardLast4: Int?
    public var dateFormat: String?

    public init(date: Int? = nil, description: Int? = nil, amount: Int? = nil,
                debit: Int? = nil, credit: Int? = nil, currency: Int? = nil,
                originalAmount: Int? = nil, originalCurrency: Int? = nil,
                cardLast4: Int? = nil, dateFormat: String? = nil) {
        self.date = date
        self.description = description
        self.amount = amount
        self.debit = debit
        self.credit = credit
        self.currency = currency
        self.originalAmount = originalAmount
        self.originalCurrency = originalCurrency
        self.cardLast4 = cardLast4
        self.dateFormat = dateFormat
    }
}

// MARK: - bank_guess

/// Detection result for BankConfirmView. Confidence ≥ 0.8 renders the
/// "We think this statement is from {Bank}" confirm path; anything the
/// detector isn't sure about comes back nil instead of a wild guess.
public struct BankGuess: Equatable {
    public let name: String
    public let confidence: Double // 0…1

    public init(name: String, confidence: Double) {
        self.name = name
        self.confidence = confidence
    }
}
