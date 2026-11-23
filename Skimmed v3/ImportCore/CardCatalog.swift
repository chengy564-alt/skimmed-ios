import Foundation

/// ImportCore — worldwide institution & card-product catalogue
///
/// Local, on-device catalogue of banks and their card products, keyed by
/// issuing market (bank products are market-specific: HSBC Hong Kong and
/// HSBC UK are distinct entries even though they share a brand). Drives the
/// bank/card pickers at every statement-upload boundary and the published-
/// terms half of trip advice.
///
/// Data integrity rules (per the product plan):
///   - Product NAMES/networks/kinds are seeded from well-known public
///     issuer lineups. Published fee metadata exists ONLY where verified
///     against the linked issuer source on `lastVerifiedAt` — never
///     invented. Everything unverified stays nil.
///   - The UI must degrade honestly for bank-only or user-entered cards.
///   - A future signed public catalogue file could replace `seed` — the
///     shapes are Codable for exactly that — but nothing here touches the
///     network now.
public struct Institution: Codable, Identifiable, Equatable, Sendable {
    public let id: String // stable, e.g. "hsbc-hk"
    public let market: String // ISO 3166 issuing market, e.g. "HK"
    public let name: String // display/legal name, e.g. "HSBC Hong Kong"
    public let brand: String // shared brand for BankMark colors, e.g. "HSBC"
    public let aliases: [String] // lowercase match tokens
    public let bicPrefixes: [String] // 4-letter SWIFT institution codes
    public let isPopular: Bool // floats to the top of its market's picker

    public init(id: String, market: String, name: String, brand: String,
                aliases: [String], bicPrefixes: [String] = [], isPopular: Bool = false) {
        self.id = id
        self.market = market
        self.name = name
        self.brand = brand
        self.aliases = aliases
        self.bicPrefixes = bicPrefixes
        self.isPopular = isPopular
    }
}

public struct CardProduct: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case credit, debit }

    public let id: String // stable, e.g. "hsbc-hk-red"
    public let institutionID: String
    public let market: String
    public let name: String // official product name
    public let aliases: [String] // lowercase match tokens (statement text)
    public let network: String? // "Visa", "Mastercard", "Amex", "JCB", …
    public let kind: Kind
    public let isActive: Bool // false = legacy/discontinued, still selectable
    /// Published foreign-transaction fee (percent) — ONLY set when verified
    /// against `sourceURL` on `lastVerifiedAt`. Nil = not yet verified.
    public let publishedFXFeePct: Double?
    public let rewardsNote: String?
    public let sourceURL: String?
    public let effectiveDate: String? // ISO date the terms took effect
    public let lastVerifiedAt: String? // ISO date we last checked the source

    public init(id: String, institutionID: String, market: String, name: String,
                aliases: [String] = [], network: String? = nil, kind: Kind = .credit,
                isActive: Bool = true, publishedFXFeePct: Double? = nil,
                rewardsNote: String? = nil, sourceURL: String? = nil,
                effectiveDate: String? = nil, lastVerifiedAt: String? = nil) {
        self.id = id
        self.institutionID = institutionID
        self.market = market
        self.name = name
        self.aliases = aliases
        self.network = network
        self.kind = kind
        self.isActive = isActive
        self.publishedFXFeePct = publishedFXFeePct
        self.rewardsNote = rewardsNote
        self.sourceURL = sourceURL
        self.effectiveDate = effectiveDate
        self.lastVerifiedAt = lastVerifiedAt
    }
}

/// How confident the catalogue is about an automatic match — shown to the
/// user, who confirms anything below `.exact`.
public enum CatalogConfidence: String, Codable, Sendable {
    case exact // statement names the product / bank+last4 previously confirmed
    case likely // strong single-signal match (detector hit, one candidate)
    case uncertain // weak/ambiguous — lead with the picker
}

public enum CardCatalog {

    // MARK: - Lookup

    public static func institutions(market: String) -> [Institution] {
        seed.filter { $0.market == market }
            .sorted { ($0.isPopular ? 0 : 1, $0.name) < ($1.isPopular ? 0 : 1, $1.name) }
    }

    public static var markets: [String] {
        Array(Set(seed.map(\.market))).sorted()
    }

    public static func institution(id: String) -> Institution? {
        seed.first { $0.id == id }
    }

    /// Country-filtered search: popular first, then name; matches name or
    /// alias substrings. Empty query returns the full market list.
    public static func searchInstitutions(market: String, query: String) -> [Institution] {
        let all = institutions(market: market)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { inst in
            inst.name.lowercased().contains(q) || inst.aliases.contains { $0.contains(q) }
        }
    }

    /// Maps a detected bank name (BankDetector output or a persisted
    /// free-text `ImportedCard.bank`) to a market's institution. This is the
    /// non-destructive migration path for pre-catalogue cards: alias match,
    /// never a data rewrite.
    public static func institution(named name: String, market: String) -> Institution? {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty else { return nil }
        // An exact display-name match anywhere is unambiguous and wins its
        // own market — "HSBC UK" must resolve to HSBC UK even when the
        // requested market is HK, never fuzzy-match to HSBC Hong Kong.
        if let exactAnywhere = seed.first(where: { $0.name.lowercased() == lower }) {
            return exactAnywhere
        }
        let inMarket = seed.filter { $0.market == market }
        if let exact = inMarket.first(where: { $0.brand.lowercased() == lower }) {
            return exact
        }
        return inMarket.first { $0.aliases.contains { lower.contains($0) || $0.contains(lower) } }
    }

    public static func products(institutionID: String) -> [CardProduct] {
        productSeed.filter { $0.institutionID == institutionID }
            .sorted { ($0.isActive ? 0 : 1, $0.name) < ($1.isActive ? 0 : 1, $1.name) }
    }

    public static func product(id: String) -> CardProduct? {
        productSeed.first { $0.id == id }
    }

    /// Searchable product list within one institution.
    public static func searchProducts(institutionID: String, query: String) -> [CardProduct] {
        let all = products(institutionID: institutionID)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { p in
            p.name.lowercased().contains(q) || p.aliases.contains { $0.contains(q) }
        }
    }

    /// If the statement text explicitly names one of the institution's
    /// products, return it (preselect-with-evidence; never claimed as exact
    /// without text support).
    public static func productNamed(in text: String, institutionID: String) -> CardProduct? {
        let lower = text.lowercased()
        return products(institutionID: institutionID).first { p in
            lower.contains(p.name.lowercased()) || p.aliases.contains { lower.contains($0) }
        }
    }

    // MARK: - Seed: institutions
    // Name-level coverage across the plan's markets. Popularity flags drive
    // picker ordering only.

    public static let seed: [Institution] = [
        // Hong Kong
        Institution(id: "hsbc-hk", market: "HK", name: "HSBC Hong Kong", brand: "HSBC", aliases: ["hsbc"], bicPrefixes: ["HSBC"], isPopular: true),
        Institution(id: "hangseng-hk", market: "HK", name: "Hang Seng Bank", brand: "Hang Seng", aliases: ["hang seng"], bicPrefixes: ["HASE"], isPopular: true),
        Institution(id: "sc-hk", market: "HK", name: "Standard Chartered Hong Kong", brand: "Standard Chartered", aliases: ["standard chartered", "sc "], bicPrefixes: ["SCBL"], isPopular: true),
        Institution(id: "boc-hk", market: "HK", name: "Bank of China (Hong Kong)", brand: "Bank of China", aliases: ["bank of china", "bochk", "boc"], bicPrefixes: ["BKCH"], isPopular: true),
        Institution(id: "bea-hk", market: "HK", name: "Bank of East Asia", brand: "BEA", aliases: ["bank of east asia", "bea"], bicPrefixes: ["BEAS"]),
        Institution(id: "dbs-hk", market: "HK", name: "DBS Hong Kong", brand: "DBS", aliases: ["dbs"], bicPrefixes: ["DHBK"], isPopular: true),
        Institution(id: "citi-hk", market: "HK", name: "Citibank Hong Kong", brand: "Citibank", aliases: ["citibank", "citi"], bicPrefixes: ["CITI"], isPopular: true),
        Institution(id: "mox-hk", market: "HK", name: "Mox Bank", brand: "Mox", aliases: ["mox"]),
        Institution(id: "za-hk", market: "HK", name: "ZA Bank", brand: "ZA", aliases: ["za bank"]),
        Institution(id: "livi-hk", market: "HK", name: "livi Bank", brand: "livi", aliases: ["livi"]),
        // United States
        Institution(id: "chase-us", market: "US", name: "Chase", brand: "Chase", aliases: ["chase", "jpmorgan", "jp morgan"], bicPrefixes: ["CHAS"], isPopular: true),
        Institution(id: "bofa-us", market: "US", name: "Bank of America", brand: "Bank of America", aliases: ["bank of america", "bofa"], bicPrefixes: ["BOFA"], isPopular: true),
        Institution(id: "wells-us", market: "US", name: "Wells Fargo", brand: "Wells Fargo", aliases: ["wells fargo"], bicPrefixes: ["WFBI"], isPopular: true),
        Institution(id: "citi-us", market: "US", name: "Citi", brand: "Citibank", aliases: ["citibank", "citi"], bicPrefixes: ["CITI"], isPopular: true),
        Institution(id: "capone-us", market: "US", name: "Capital One", brand: "Capital One", aliases: ["capital one"], bicPrefixes: ["NFBK"], isPopular: true),
        Institution(id: "amex-us", market: "US", name: "American Express", brand: "American Express", aliases: ["american express", "amex"], bicPrefixes: ["AEIB"], isPopular: true),
        Institution(id: "discover-us", market: "US", name: "Discover", brand: "Discover", aliases: ["discover"]),
        Institution(id: "usbank-us", market: "US", name: "U.S. Bank", brand: "U.S. Bank", aliases: ["us bank", "u.s. bank"]),
        Institution(id: "schwab-us", market: "US", name: "Charles Schwab", brand: "Charles Schwab", aliases: ["schwab"]),
        Institution(id: "chime-us", market: "US", name: "Chime", brand: "Chime", aliases: ["chime"]),
        // United Kingdom
        Institution(id: "barclays-gb", market: "GB", name: "Barclays / Barclaycard", brand: "Barclays", aliases: ["barclays", "barclaycard"], bicPrefixes: ["BARC", "BUKB"], isPopular: true),
        Institution(id: "hsbc-gb", market: "GB", name: "HSBC UK", brand: "HSBC", aliases: ["hsbc"], bicPrefixes: ["HBUK", "HSBC"], isPopular: true),
        Institution(id: "lloyds-gb", market: "GB", name: "Lloyds Bank", brand: "Lloyds", aliases: ["lloyds"], bicPrefixes: ["LOYD"], isPopular: true),
        Institution(id: "halifax-gb", market: "GB", name: "Halifax", brand: "Halifax", aliases: ["halifax"], bicPrefixes: ["HLFX"], isPopular: true),
        Institution(id: "natwest-gb", market: "GB", name: "NatWest", brand: "NatWest", aliases: ["natwest"], bicPrefixes: ["NWBK"], isPopular: true),
        Institution(id: "santander-gb", market: "GB", name: "Santander UK", brand: "Santander", aliases: ["santander"], bicPrefixes: ["ABBY"]),
        Institution(id: "nationwide-gb", market: "GB", name: "Nationwide", brand: "Nationwide", aliases: ["nationwide"], bicPrefixes: ["NAIA"]),
        Institution(id: "monzo-gb", market: "GB", name: "Monzo", brand: "Monzo", aliases: ["monzo"], bicPrefixes: ["MONZ"], isPopular: true),
        Institution(id: "starling-gb", market: "GB", name: "Starling Bank", brand: "Starling", aliases: ["starling"], bicPrefixes: ["SRLG"]),
        Institution(id: "amex-gb", market: "GB", name: "American Express UK", brand: "American Express", aliases: ["american express", "amex"], bicPrefixes: ["AEIB"]),
        // Singapore
        Institution(id: "dbs-sg", market: "SG", name: "DBS Singapore", brand: "DBS", aliases: ["dbs", "posb"], bicPrefixes: ["DBSS"], isPopular: true),
        Institution(id: "ocbc-sg", market: "SG", name: "OCBC", brand: "OCBC", aliases: ["ocbc"], bicPrefixes: ["OCBC"], isPopular: true),
        Institution(id: "uob-sg", market: "SG", name: "UOB", brand: "UOB", aliases: ["uob", "united overseas"], bicPrefixes: ["UOVB"], isPopular: true),
        Institution(id: "citi-sg", market: "SG", name: "Citibank Singapore", brand: "Citibank", aliases: ["citibank", "citi"], bicPrefixes: ["CITI"]),
        Institution(id: "sc-sg", market: "SG", name: "Standard Chartered Singapore", brand: "Standard Chartered", aliases: ["standard chartered"], bicPrefixes: ["SCBL"]),
        Institution(id: "hsbc-sg", market: "SG", name: "HSBC Singapore", brand: "HSBC", aliases: ["hsbc"], bicPrefixes: ["HSBC"]),
        // Canada
        Institution(id: "rbc-ca", market: "CA", name: "RBC Royal Bank", brand: "RBC", aliases: ["rbc", "royal bank"], bicPrefixes: ["ROYC"], isPopular: true),
        Institution(id: "td-ca", market: "CA", name: "TD Canada Trust", brand: "TD", aliases: ["td bank", "td canada", "toronto-dominion"], bicPrefixes: ["TDOM"], isPopular: true),
        Institution(id: "scotia-ca", market: "CA", name: "Scotiabank", brand: "Scotiabank", aliases: ["scotiabank", "scotia"], bicPrefixes: ["NOSC"], isPopular: true),
        Institution(id: "bmo-ca", market: "CA", name: "BMO", brand: "BMO", aliases: ["bmo", "bank of montreal"], bicPrefixes: ["BOFM"], isPopular: true),
        Institution(id: "cibc-ca", market: "CA", name: "CIBC", brand: "CIBC", aliases: ["cibc"], bicPrefixes: ["CIBC"]),
        Institution(id: "amex-ca", market: "CA", name: "American Express Canada", brand: "American Express", aliases: ["american express", "amex"]),
        // Australia
        Institution(id: "cba-au", market: "AU", name: "Commonwealth Bank", brand: "CommBank", aliases: ["commonwealth bank", "commbank", "cba"], bicPrefixes: ["CTBA"], isPopular: true),
        Institution(id: "westpac-au", market: "AU", name: "Westpac", brand: "Westpac", aliases: ["westpac"], bicPrefixes: ["WPAC"], isPopular: true),
        Institution(id: "anz-au", market: "AU", name: "ANZ", brand: "ANZ", aliases: ["anz"], bicPrefixes: ["ANZB"], isPopular: true),
        Institution(id: "nab-au", market: "AU", name: "NAB", brand: "NAB", aliases: ["nab", "national australia"], bicPrefixes: ["NATA"], isPopular: true),
        Institution(id: "macquarie-au", market: "AU", name: "Macquarie Bank", brand: "Macquarie", aliases: ["macquarie"], bicPrefixes: ["MACQ"]),
        Institution(id: "latitude-au", market: "AU", name: "Latitude Financial", brand: "Latitude", aliases: ["latitude", "28 degrees"]),
        // New Zealand
        Institution(id: "anz-nz", market: "NZ", name: "ANZ New Zealand", brand: "ANZ", aliases: ["anz"], bicPrefixes: ["ANZB"], isPopular: true),
        Institution(id: "asb-nz", market: "NZ", name: "ASB", brand: "ASB", aliases: ["asb"], bicPrefixes: ["ASBB"], isPopular: true),
        Institution(id: "westpac-nz", market: "NZ", name: "Westpac NZ", brand: "Westpac", aliases: ["westpac"], bicPrefixes: ["WPAC"]),
        Institution(id: "bnz-nz", market: "NZ", name: "BNZ", brand: "BNZ", aliases: ["bnz", "bank of new zealand"], bicPrefixes: ["BKNZ"]),
        // Japan
        Institution(id: "mufg-jp", market: "JP", name: "MUFG Bank", brand: "MUFG", aliases: ["mufg", "mitsubishi ufj"], bicPrefixes: ["BOTK"], isPopular: true),
        Institution(id: "smbc-jp", market: "JP", name: "Sumitomo Mitsui (SMBC)", brand: "SMBC", aliases: ["smbc", "sumitomo mitsui"], bicPrefixes: ["SMBC"], isPopular: true),
        Institution(id: "mizuho-jp", market: "JP", name: "Mizuho Bank", brand: "Mizuho", aliases: ["mizuho"], bicPrefixes: ["MHCB"]),
        Institution(id: "rakuten-jp", market: "JP", name: "Rakuten Card", brand: "Rakuten", aliases: ["rakuten"], isPopular: true),
        Institution(id: "epos-jp", market: "JP", name: "Epos Card", brand: "Epos", aliases: ["epos"]),
        // South Korea
        Institution(id: "kb-kr", market: "KR", name: "KB Kookmin Card", brand: "KB", aliases: ["kookmin", "kb card"], bicPrefixes: ["CZNB"], isPopular: true),
        Institution(id: "shinhan-kr", market: "KR", name: "Shinhan Card", brand: "Shinhan", aliases: ["shinhan"], bicPrefixes: ["SHBK"], isPopular: true),
        Institution(id: "samsung-kr", market: "KR", name: "Samsung Card", brand: "Samsung", aliases: ["samsung card"]),
        Institution(id: "hyundai-kr", market: "KR", name: "Hyundai Card", brand: "Hyundai", aliases: ["hyundai card"]),
        Institution(id: "hana-kr", market: "KR", name: "Hana Card", brand: "Hana", aliases: ["hana"], bicPrefixes: ["HNBN"]),
        // Taiwan
        Institution(id: "ctbc-tw", market: "TW", name: "CTBC Bank", brand: "CTBC", aliases: ["ctbc", "chinatrust"], bicPrefixes: ["CTCB"], isPopular: true),
        Institution(id: "cathay-tw", market: "TW", name: "Cathay United Bank", brand: "Cathay", aliases: ["cathay united"], bicPrefixes: ["UWCB"], isPopular: true),
        Institution(id: "esun-tw", market: "TW", name: "E.SUN Bank", brand: "E.SUN", aliases: ["e.sun", "esun"], bicPrefixes: ["ESUN"]),
        Institution(id: "taishin-tw", market: "TW", name: "Taishin Bank", brand: "Taishin", aliases: ["taishin"], bicPrefixes: ["TSIB"]),
        Institution(id: "fubon-tw", market: "TW", name: "Taipei Fubon Bank", brand: "Fubon", aliases: ["fubon"], bicPrefixes: ["TPBK"]),
        // Germany
        Institution(id: "deutsche-de", market: "DE", name: "Deutsche Bank", brand: "Deutsche Bank", aliases: ["deutsche bank"], bicPrefixes: ["DEUT"], isPopular: true),
        Institution(id: "commerzbank-de", market: "DE", name: "Commerzbank", brand: "Commerzbank", aliases: ["commerzbank"], bicPrefixes: ["COBA"]),
        Institution(id: "dkb-de", market: "DE", name: "DKB", brand: "DKB", aliases: ["dkb", "deutsche kreditbank"], bicPrefixes: ["BYLA"]),
        Institution(id: "n26-de", market: "DE", name: "N26", brand: "N26", aliases: ["n26"], bicPrefixes: ["NTSB"], isPopular: true),
        // France
        Institution(id: "bnp-fr", market: "FR", name: "BNP Paribas", brand: "BNP Paribas", aliases: ["bnp"], bicPrefixes: ["BNPA"], isPopular: true),
        Institution(id: "sg-fr", market: "FR", name: "Société Générale", brand: "Société Générale", aliases: ["societe generale", "société générale"], bicPrefixes: ["SOGE"]),
        Institution(id: "ca-fr", market: "FR", name: "Crédit Agricole", brand: "Crédit Agricole", aliases: ["credit agricole", "crédit agricole"], bicPrefixes: ["AGRI"]),
        // Netherlands
        Institution(id: "ing-nl", market: "NL", name: "ING", brand: "ING", aliases: ["ing"], bicPrefixes: ["INGB"], isPopular: true),
        Institution(id: "abn-nl", market: "NL", name: "ABN AMRO", brand: "ABN AMRO", aliases: ["abn amro", "abn"], bicPrefixes: ["ABNA"], isPopular: true),
        Institution(id: "rabo-nl", market: "NL", name: "Rabobank", brand: "Rabobank", aliases: ["rabobank", "rabo"], bicPrefixes: ["RABO"]),
        // Spain
        Institution(id: "santander-es", market: "ES", name: "Santander España", brand: "Santander", aliases: ["santander"], bicPrefixes: ["BSCH"], isPopular: true),
        Institution(id: "bbva-es", market: "ES", name: "BBVA", brand: "BBVA", aliases: ["bbva"], bicPrefixes: ["BBVA"], isPopular: true),
        Institution(id: "caixa-es", market: "ES", name: "CaixaBank", brand: "CaixaBank", aliases: ["caixabank", "caixa"], bicPrefixes: ["CAIX"]),
        // Italy
        Institution(id: "intesa-it", market: "IT", name: "Intesa Sanpaolo", brand: "Intesa", aliases: ["intesa"], bicPrefixes: ["BCIT"], isPopular: true),
        Institution(id: "unicredit-it", market: "IT", name: "UniCredit", brand: "UniCredit", aliases: ["unicredit"], bicPrefixes: ["UNCR"], isPopular: true),
        // UAE
        Institution(id: "enbd-ae", market: "AE", name: "Emirates NBD", brand: "Emirates NBD", aliases: ["emirates nbd", "enbd"], bicPrefixes: ["EBIL"], isPopular: true),
        Institution(id: "fab-ae", market: "AE", name: "First Abu Dhabi Bank", brand: "FAB", aliases: ["first abu dhabi", "fab"], bicPrefixes: ["NBAD"], isPopular: true),
        Institution(id: "adcb-ae", market: "AE", name: "ADCB", brand: "ADCB", aliases: ["adcb", "abu dhabi commercial"], bicPrefixes: ["ADCB"]),
        Institution(id: "mashreq-ae", market: "AE", name: "Mashreq", brand: "Mashreq", aliases: ["mashreq"], bicPrefixes: ["BOML"]),
        // International (multi-market e-money issuers; market "INTL")
        Institution(id: "wise-intl", market: "INTL", name: "Wise", brand: "Wise", aliases: ["wise", "transferwise"], bicPrefixes: ["TRWI"], isPopular: true),
        Institution(id: "revolut-intl", market: "INTL", name: "Revolut", brand: "Revolut", aliases: ["revolut"], bicPrefixes: ["REVO"], isPopular: true),
    ]

    // MARK: - Seed: card products (names/networks only; fee metadata unverified => nil)

    public static let productSeed: [CardProduct] = [
        // HSBC HK
        CardProduct(id: "hsbc-hk-red", institutionID: "hsbc-hk", market: "HK", name: "Red Credit Card", aliases: ["red card"], network: "Mastercard", publishedFXFeePct: 1.95, sourceURL: "https://www.hsbc.com.hk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-hk-everymile", institutionID: "hsbc-hk", market: "HK", name: "EveryMile Credit Card", aliases: ["everymile"], network: "Mastercard", publishedFXFeePct: 1.95, sourceURL: "https://www.hsbc.com.hk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-hk-vsig", institutionID: "hsbc-hk", market: "HK", name: "Visa Signature Card", network: "Visa", publishedFXFeePct: 1.95, sourceURL: "https://www.hsbc.com.hk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-hk-premier", institutionID: "hsbc-hk", market: "HK", name: "Premier Mastercard", network: "Mastercard", publishedFXFeePct: 1.95, sourceURL: "https://www.hsbc.com.hk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        // Hang Seng
        CardProduct(id: "hangseng-hk-mmpower", institutionID: "hangseng-hk", market: "HK", name: "MMPOWER World Mastercard", aliases: ["mmpower"], network: "Mastercard"),
        CardProduct(id: "hangseng-hk-enjoy", institutionID: "hangseng-hk", market: "HK", name: "enJoy Card", aliases: ["enjoy"], network: "Visa"),
        // SC HK
        CardProduct(id: "sc-hk-cathay", institutionID: "sc-hk", market: "HK", name: "Cathay Mastercard", aliases: ["cathay"], network: "Mastercard"),
        CardProduct(id: "sc-hk-smart", institutionID: "sc-hk", market: "HK", name: "Smart Card", network: "Visa"),
        CardProduct(id: "sc-hk-simplycash", institutionID: "sc-hk", market: "HK", name: "Simply Cash Visa Card", aliases: ["simply cash"], network: "Visa"),
        // BOC HK
        CardProduct(id: "boc-hk-cheers", institutionID: "boc-hk", market: "HK", name: "Cheers Card", network: "Visa"),
        CardProduct(id: "boc-hk-chill", institutionID: "boc-hk", market: "HK", name: "Chill Card", network: "Visa"),
        // DBS HK
        CardProduct(id: "dbs-hk-black", institutionID: "dbs-hk", market: "HK", name: "Black World Mastercard", aliases: ["black card"], network: "Mastercard"),
        CardProduct(id: "dbs-hk-eminent", institutionID: "dbs-hk", market: "HK", name: "Eminent Card", network: "Visa"),
        CardProduct(id: "dbs-hk-livefresh", institutionID: "dbs-hk", market: "HK", name: "Live Fresh Card", aliases: ["live fresh"], network: "Visa"),
        // Citi HK
        CardProduct(id: "citi-hk-cashback", institutionID: "citi-hk", market: "HK", name: "Citi Cash Back Card", aliases: ["cash back"], network: "Mastercard"),
        CardProduct(id: "citi-hk-rewards", institutionID: "citi-hk", market: "HK", name: "Citi Rewards Card", network: "Mastercard"),
        CardProduct(id: "citi-hk-premiermiles", institutionID: "citi-hk", market: "HK", name: "Citi PremierMiles Card", aliases: ["premiermiles"], network: "Mastercard"),
        CardProduct(id: "citi-hk-prestige", institutionID: "citi-hk", market: "HK", name: "Citi Prestige Card", network: "Mastercard"),
        // Mox / ZA / livi (debit)
        CardProduct(id: "mox-hk-card", institutionID: "mox-hk", market: "HK", name: "Mox Card", network: "Mastercard", kind: .debit),
        CardProduct(id: "za-hk-card", institutionID: "za-hk", market: "HK", name: "ZA Card", network: "Visa", kind: .debit),
        CardProduct(id: "livi-hk-card", institutionID: "livi-hk", market: "HK", name: "livi Debit Card", network: "Mastercard", kind: .debit),
        // Chase US
        CardProduct(id: "chase-us-csp", institutionID: "chase-us", market: "US", name: "Sapphire Preferred", aliases: ["sapphire preferred"], network: "Visa", publishedFXFeePct: 0, sourceURL: "https://creditcards.chase.com/no-foreign-transaction-fee-credit-cards", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "chase-us-csr", institutionID: "chase-us", market: "US", name: "Sapphire Reserve", aliases: ["sapphire reserve"], network: "Visa", publishedFXFeePct: 0, sourceURL: "https://creditcards.chase.com/no-foreign-transaction-fee-credit-cards", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "chase-us-fu", institutionID: "chase-us", market: "US", name: "Freedom Unlimited", aliases: ["freedom unlimited"], network: "Visa"),
        CardProduct(id: "chase-us-ff", institutionID: "chase-us", market: "US", name: "Freedom Flex", aliases: ["freedom flex"], network: "Mastercard"),
        // Amex US
        CardProduct(id: "amex-us-platinum", institutionID: "amex-us", market: "US", name: "The Platinum Card", aliases: ["platinum"], network: "Amex", publishedFXFeePct: 0, sourceURL: "https://global.americanexpress.com/card-benefits/detail/no-foreign-transaction-fees/platinum", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "amex-us-gold", institutionID: "amex-us", market: "US", name: "American Express Gold Card", aliases: ["gold card"], network: "Amex", publishedFXFeePct: 0, sourceURL: "https://www.americanexpress.com/us/credit-cards/category/no-foreign-transaction-fee/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "amex-us-green", institutionID: "amex-us", market: "US", name: "American Express Green Card", aliases: ["green card"], network: "Amex", publishedFXFeePct: 0, sourceURL: "https://www.americanexpress.com/us/credit-cards/category/no-foreign-transaction-fee/", lastVerifiedAt: "2026-07-13"),
        // BofA
        CardProduct(id: "bofa-us-travel", institutionID: "bofa-us", market: "US", name: "Travel Rewards", aliases: ["travel rewards"], network: "Visa"),
        CardProduct(id: "bofa-us-cash", institutionID: "bofa-us", market: "US", name: "Customized Cash Rewards", aliases: ["customized cash"], network: "Visa"),
        // Capital One
        CardProduct(id: "capone-us-venture", institutionID: "capone-us", market: "US", name: "Venture Rewards", aliases: ["venture"], network: "Visa", publishedFXFeePct: 0, sourceURL: "https://www.capitalone.com/learn-grow/money-management/no-foreign-transaction-fee-credit-card/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "capone-us-venturex", institutionID: "capone-us", market: "US", name: "Venture X", aliases: ["venture x"], network: "Visa", publishedFXFeePct: 0, sourceURL: "https://www.capitalone.com/learn-grow/money-management/no-foreign-transaction-fee-credit-card/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "capone-us-quicksilver", institutionID: "capone-us", market: "US", name: "Quicksilver", aliases: ["quicksilver"], network: "Mastercard", publishedFXFeePct: 0, sourceURL: "https://www.capitalone.com/learn-grow/money-management/no-foreign-transaction-fee-credit-card/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "capone-us-savor", institutionID: "capone-us", market: "US", name: "Savor", aliases: ["savor"], network: "Mastercard", publishedFXFeePct: 0, sourceURL: "https://www.capitalone.com/learn-grow/money-management/no-foreign-transaction-fee-credit-card/", lastVerifiedAt: "2026-07-13"),
        // Citi US
        CardProduct(id: "citi-us-strata", institutionID: "citi-us", market: "US", name: "Strata Premier", aliases: ["strata premier"], network: "Mastercard", publishedFXFeePct: 0, sourceURL: "https://www.citi.com/credit-cards/citi-strata-premier-credit-card", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "citi-us-doublecash", institutionID: "citi-us", market: "US", name: "Double Cash", aliases: ["double cash"], network: "Mastercard"),
        // Wells / Discover / US Bank / Schwab / Chime
        CardProduct(id: "wells-us-activecash", institutionID: "wells-us", market: "US", name: "Active Cash", aliases: ["active cash"], network: "Visa"),
        CardProduct(id: "wells-us-autograph", institutionID: "wells-us", market: "US", name: "Autograph", aliases: ["autograph"], network: "Visa"),
        CardProduct(id: "discover-us-it", institutionID: "discover-us", market: "US", name: "Discover it", aliases: ["discover it"], network: "Discover", publishedFXFeePct: 0, sourceURL: "https://www.discover.com/credit-cards/card-smarts/discover-card-foreign-transaction-fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "usbank-us-altitude", institutionID: "usbank-us", market: "US", name: "Altitude Go", aliases: ["altitude"], network: "Visa"),
        CardProduct(id: "schwab-us-investor", institutionID: "schwab-us", market: "US", name: "Investor Checking Debit", network: "Visa", kind: .debit),
        CardProduct(id: "chime-us-debit", institutionID: "chime-us", market: "US", name: "Chime Visa Debit", network: "Visa", kind: .debit),
        // UK
        CardProduct(id: "barclays-gb-rewards", institutionID: "barclays-gb", market: "GB", name: "Barclaycard Rewards", aliases: ["rewards"], network: "Visa", publishedFXFeePct: 0, rewardsNote: "0.25% cashback on everyday spending", sourceURL: "https://www.barclaycard.co.uk/personal/credit-cards/barclaycard-rewards", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "barclays-gb-avios", institutionID: "barclays-gb", market: "GB", name: "Barclaycard Avios", aliases: ["avios"], network: "Visa", publishedFXFeePct: 2.99, sourceURL: "https://www.barclaycard.co.uk/personal/credit-cards/understanding-fees", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-gb-rewards", institutionID: "hsbc-gb", market: "GB", name: "Rewards Credit Card", aliases: ["rewards"], network: "Visa", publishedFXFeePct: 2.99, sourceURL: "https://www.hsbc.co.uk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-gb-purchaseplus", institutionID: "hsbc-gb", market: "GB", name: "Purchase Plus Credit Card", aliases: ["purchase plus"], network: "Visa", publishedFXFeePct: 2.99, sourceURL: "https://www.hsbc.co.uk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-gb-balancetransfer", institutionID: "hsbc-gb", market: "GB", name: "Balance Transfer Credit Card", aliases: ["balance transfer"], network: "Visa", publishedFXFeePct: 2.99, sourceURL: "https://www.hsbc.co.uk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-gb-classic", institutionID: "hsbc-gb", market: "GB", name: "Classic Credit Card", aliases: ["classic"], network: "Visa", publishedFXFeePct: 2.99, sourceURL: "https://www.hsbc.co.uk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-gb-premier", institutionID: "hsbc-gb", market: "GB", name: "Premier Credit Card", network: "Mastercard", publishedFXFeePct: 2.99, sourceURL: "https://www.hsbc.co.uk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-gb-premierwe", institutionID: "hsbc-gb", market: "GB", name: "Premier World Elite Mastercard", aliases: ["world elite"], network: "Mastercard", publishedFXFeePct: 2.99, sourceURL: "https://www.hsbc.co.uk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-gb-student", institutionID: "hsbc-gb", market: "GB", name: "Student Credit Card", aliases: ["student"], network: "Visa", publishedFXFeePct: 2.99, sourceURL: "https://www.hsbc.co.uk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-gb-debit", institutionID: "hsbc-gb", market: "GB", name: "HSBC UK Debit Card", network: "Visa", kind: .debit, publishedFXFeePct: 2.75, sourceURL: "https://www.hsbc.co.uk/international/using-your-card-abroad-fees-and-charges-explained/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-gb-globalmoney", institutionID: "hsbc-gb", market: "GB", name: "Global Money Debit Card", aliases: ["global money"], network: "Visa", kind: .debit),
        CardProduct(id: "halifax-gb-clarity", institutionID: "halifax-gb", market: "GB", name: "Clarity Credit Card", aliases: ["clarity"], network: "Mastercard", publishedFXFeePct: 0, sourceURL: "https://www.halifax.co.uk/creditcards/travel.html", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "lloyds-gb-cashback", institutionID: "lloyds-gb", market: "GB", name: "Cashback Credit Card", network: "Mastercard"),
        CardProduct(id: "natwest-gb-reward", institutionID: "natwest-gb", market: "GB", name: "Reward Credit Card", network: "Mastercard", publishedFXFeePct: 2.75, sourceURL: "https://www.natwest.com/support-centre/payments/general/what-is-the-foreign-transaction-fee-on-my-credit-card.html", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "santander-gb-allinone", institutionID: "santander-gb", market: "GB", name: "All in One Credit Card", aliases: ["all in one"], network: "Mastercard"),
        CardProduct(id: "monzo-gb-debit", institutionID: "monzo-gb", market: "GB", name: "Monzo Debit Card", network: "Mastercard", kind: .debit, publishedFXFeePct: 0, sourceURL: "https://monzo.com/ecb-rates", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "starling-gb-debit", institutionID: "starling-gb", market: "GB", name: "Starling Debit Card", network: "Mastercard", kind: .debit, publishedFXFeePct: 0, sourceURL: "https://www.starlingbank.com/travel/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "amex-gb-ba", institutionID: "amex-gb", market: "GB", name: "British Airways American Express", aliases: ["british airways"], network: "Amex"),
        CardProduct(id: "amex-gb-gold", institutionID: "amex-gb", market: "GB", name: "American Express Preferred Rewards Gold", aliases: ["gold"], network: "Amex"),
        // Singapore
        CardProduct(id: "dbs-sg-altitude", institutionID: "dbs-sg", market: "SG", name: "Altitude Visa Signature", aliases: ["altitude"], network: "Visa"),
        CardProduct(id: "dbs-sg-livefresh", institutionID: "dbs-sg", market: "SG", name: "Live Fresh Card", aliases: ["live fresh"], network: "Visa"),
        CardProduct(id: "dbs-sg-womans", institutionID: "dbs-sg", market: "SG", name: "Woman's World Card", aliases: ["woman's world"], network: "Mastercard"),
        CardProduct(id: "ocbc-sg-365", institutionID: "ocbc-sg", market: "SG", name: "OCBC 365 Credit Card", aliases: ["365"], network: "Visa"),
        CardProduct(id: "ocbc-sg-90n", institutionID: "ocbc-sg", market: "SG", name: "90°N Card", aliases: ["90n", "90°n"], network: "Mastercard"),
        CardProduct(id: "uob-sg-prvi", institutionID: "uob-sg", market: "SG", name: "PRVI Miles Card", aliases: ["prvi"], network: "Visa"),
        CardProduct(id: "uob-sg-one", institutionID: "uob-sg", market: "SG", name: "UOB One Card", aliases: ["one card"], network: "Visa"),
        CardProduct(id: "uob-sg-krisflyer", institutionID: "uob-sg", market: "SG", name: "KrisFlyer UOB Credit Card", aliases: ["krisflyer"], network: "Visa"),
        CardProduct(id: "citi-sg-premiermiles", institutionID: "citi-sg", market: "SG", name: "Citi PremierMiles Card", aliases: ["premiermiles"], network: "Mastercard"),
        // Canada
        CardProduct(id: "rbc-ca-avion", institutionID: "rbc-ca", market: "CA", name: "Avion Visa Infinite", aliases: ["avion"], network: "Visa"),
        CardProduct(id: "td-ca-aeroplan", institutionID: "td-ca", market: "CA", name: "Aeroplan Visa Infinite", aliases: ["aeroplan"], network: "Visa"),
        CardProduct(id: "scotia-ca-passport", institutionID: "scotia-ca", market: "CA", name: "Passport Visa Infinite", aliases: ["passport"], network: "Visa", publishedFXFeePct: 0, sourceURL: "https://www.scotiabank.com/ca/en/personal/credit-cards/visa/passport-infinite-card.html", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "bmo-ca-cashback", institutionID: "bmo-ca", market: "CA", name: "CashBack World Elite Mastercard", aliases: ["cashback"], network: "Mastercard"),
        CardProduct(id: "cibc-ca-aventura", institutionID: "cibc-ca", market: "CA", name: "Aventura Visa Infinite", aliases: ["aventura"], network: "Visa"),
        CardProduct(id: "amex-ca-cobalt", institutionID: "amex-ca", market: "CA", name: "Cobalt Card", aliases: ["cobalt"], network: "Amex"),
        // Australia / NZ
        CardProduct(id: "cba-au-ultimate", institutionID: "cba-au", market: "AU", name: "Ultimate Awards", aliases: ["ultimate awards"], network: "Mastercard"),
        CardProduct(id: "westpac-au-altitude", institutionID: "westpac-au", market: "AU", name: "Altitude Rewards", aliases: ["altitude"], network: "Mastercard"),
        CardProduct(id: "anz-au-rta", institutionID: "anz-au", market: "AU", name: "Rewards Travel Adventures", aliases: ["travel adventures"], network: "Visa"),
        CardProduct(id: "nab-au-rewards", institutionID: "nab-au", market: "AU", name: "NAB Rewards", network: "Visa"),
        CardProduct(id: "latitude-au-28d", institutionID: "latitude-au", market: "AU", name: "28° Global Platinum Mastercard", aliases: ["28 degrees"], network: "Mastercard", publishedFXFeePct: 0, sourceURL: "https://www.latitudefinancial.com.au/credit-cards/28-degrees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "macquarie-au-debit", institutionID: "macquarie-au", market: "AU", name: "Macquarie Transaction Account Debit", network: "Mastercard", kind: .debit),
        CardProduct(id: "anz-nz-airpoints", institutionID: "anz-nz", market: "NZ", name: "Airpoints Visa", aliases: ["airpoints"], network: "Visa"),
        CardProduct(id: "asb-nz-visa", institutionID: "asb-nz", market: "NZ", name: "Visa Rewards", network: "Visa"),
        // Japan / Korea / Taiwan
        CardProduct(id: "rakuten-jp-card", institutionID: "rakuten-jp", market: "JP", name: "Rakuten Card", network: "Visa"),
        CardProduct(id: "epos-jp-card", institutionID: "epos-jp", market: "JP", name: "Epos Card", network: "Visa"),
        CardProduct(id: "smbc-jp-card", institutionID: "smbc-jp", market: "JP", name: "Mitsui Sumitomo Card (NL)", network: "Visa"),
        CardProduct(id: "shinhan-kr-deepdream", institutionID: "shinhan-kr", market: "KR", name: "Deep Dream Card", aliases: ["deep dream"], network: "Visa"),
        CardProduct(id: "kb-kr-star", institutionID: "kb-kr", market: "KR", name: "KB Star Card", network: "Visa"),
        CardProduct(id: "ctbc-tw-aloha", institutionID: "ctbc-tw", market: "TW", name: "ALOHA General Card", aliases: ["aloha"], network: "Visa"),
        CardProduct(id: "cathay-tw-cube", institutionID: "cathay-tw", market: "TW", name: "CUBE Card", aliases: ["cube"], network: "Visa"),
        CardProduct(id: "esun-tw-ubear", institutionID: "esun-tw", market: "TW", name: "U Bear Card", aliases: ["u bear"], network: "Mastercard"),
        // Europe
        CardProduct(id: "n26-de-standard", institutionID: "n26-de", market: "DE", name: "N26 Standard Debit", network: "Mastercard", kind: .debit),
        CardProduct(id: "dkb-de-visa", institutionID: "dkb-de", market: "DE", name: "DKB Visa Debitkarte", network: "Visa", kind: .debit),
        CardProduct(id: "ing-nl-debit", institutionID: "ing-nl", market: "NL", name: "ING Debit Card", network: "Maestro", kind: .debit),
        CardProduct(id: "bnp-fr-visa", institutionID: "bnp-fr", market: "FR", name: "Visa Premier", aliases: ["premier"], network: "Visa"),
        CardProduct(id: "bbva-es-aqua", institutionID: "bbva-es", market: "ES", name: "Tarjeta Aqua", aliases: ["aqua"], network: "Visa"),
        CardProduct(id: "intesa-it-xme", institutionID: "intesa-it", market: "IT", name: "XME Card Plus", aliases: ["xme"], network: "Mastercard"),
        // UAE
        CardProduct(id: "enbd-ae-skywards", institutionID: "enbd-ae", market: "AE", name: "Skywards Signature Card", aliases: ["skywards"], network: "Visa"),
        CardProduct(id: "fab-ae-cashback", institutionID: "fab-ae", market: "AE", name: "Cashback Credit Card", network: "Visa"),

        // Lineup depth pass — every popular institution gets its everyday
        // cards, not just the flagship (names/networks only; fees unverified).
        CardProduct(id: "chase-us-slateedge", institutionID: "chase-us", market: "US", name: "Slate Edge", aliases: ["slate"], network: "Visa"),
        CardProduct(id: "chase-us-amazonprime", institutionID: "chase-us", market: "US", name: "Prime Visa", aliases: ["prime visa", "amazon"], network: "Visa"),
        CardProduct(id: "chase-us-united", institutionID: "chase-us", market: "US", name: "United Explorer Card", aliases: ["united explorer"], network: "Visa"),
        CardProduct(id: "chase-us-southwest", institutionID: "chase-us", market: "US", name: "Southwest Rapid Rewards Plus", aliases: ["southwest"], network: "Visa"),
        CardProduct(id: "chase-us-marriott", institutionID: "chase-us", market: "US", name: "Marriott Bonvoy Boundless", aliases: ["bonvoy"], network: "Visa"),
        CardProduct(id: "chase-us-debit", institutionID: "chase-us", market: "US", name: "Chase Debit Card", network: "Visa", kind: .debit),
        CardProduct(id: "amex-us-bce", institutionID: "amex-us", market: "US", name: "Blue Cash Everyday", aliases: ["blue cash everyday"], network: "Amex"),
        CardProduct(id: "amex-us-bcp", institutionID: "amex-us", market: "US", name: "Blue Cash Preferred", aliases: ["blue cash preferred"], network: "Amex"),
        CardProduct(id: "amex-us-deltagold", institutionID: "amex-us", market: "US", name: "Delta SkyMiles Gold", aliases: ["delta"], network: "Amex"),
        CardProduct(id: "amex-us-everyday", institutionID: "amex-us", market: "US", name: "Amex EveryDay Card", aliases: ["everyday"], network: "Amex"),
        CardProduct(id: "bofa-us-unlimited", institutionID: "bofa-us", market: "US", name: "Unlimited Cash Rewards", aliases: ["unlimited cash"], network: "Visa"),
        CardProduct(id: "bofa-us-premium", institutionID: "bofa-us", market: "US", name: "Premium Rewards", aliases: ["premium rewards"], network: "Visa"),
        CardProduct(id: "bofa-us-debit", institutionID: "bofa-us", market: "US", name: "Bank of America Debit Card", network: "Visa", kind: .debit),
        CardProduct(id: "citi-us-customcash", institutionID: "citi-us", market: "US", name: "Custom Cash", aliases: ["custom cash"], network: "Mastercard"),
        CardProduct(id: "citi-us-aadvantage", institutionID: "citi-us", market: "US", name: "AAdvantage Platinum Select", aliases: ["aadvantage"], network: "Mastercard"),
        CardProduct(id: "citi-us-simplicity", institutionID: "citi-us", market: "US", name: "Simplicity Card", aliases: ["simplicity"], network: "Mastercard"),
        CardProduct(id: "wells-us-attune", institutionID: "wells-us", market: "US", name: "Attune Card", aliases: ["attune"], network: "Mastercard"),
        CardProduct(id: "wells-us-reflect", institutionID: "wells-us", market: "US", name: "Reflect Card", aliases: ["reflect"], network: "Visa"),
        CardProduct(id: "wells-us-debit", institutionID: "wells-us", market: "US", name: "Wells Fargo Debit Card", network: "Visa", kind: .debit),
        CardProduct(id: "discover-us-miles", institutionID: "discover-us", market: "US", name: "Discover it Miles", aliases: ["miles"], network: "Discover"),
        CardProduct(id: "discover-us-chrome", institutionID: "discover-us", market: "US", name: "Discover it Chrome", aliases: ["chrome"], network: "Discover"),
        CardProduct(id: "usbank-us-cashplus", institutionID: "usbank-us", market: "US", name: "Cash+ Visa Signature", aliases: ["cash+"], network: "Visa"),
        // UK depth
        CardProduct(id: "barclays-gb-forward", institutionID: "barclays-gb", market: "GB", name: "Barclaycard Forward", aliases: ["forward"], network: "Visa", publishedFXFeePct: 2.99, sourceURL: "https://www.barclaycard.co.uk/personal/credit-cards/understanding-fees", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "barclays-gb-platinum", institutionID: "barclays-gb", market: "GB", name: "Barclaycard Platinum", aliases: ["platinum"], network: "Visa", publishedFXFeePct: 2.99, sourceURL: "https://www.barclaycard.co.uk/personal/credit-cards/understanding-fees", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "barclays-gb-debit", institutionID: "barclays-gb", market: "GB", name: "Barclays Debit Card", network: "Visa", kind: .debit),
        CardProduct(id: "lloyds-gb-platinum", institutionID: "lloyds-gb", market: "GB", name: "Platinum Credit Card", aliases: ["platinum"], network: "Mastercard"),
        CardProduct(id: "lloyds-gb-debit", institutionID: "lloyds-gb", market: "GB", name: "Lloyds Debit Card", network: "Visa", kind: .debit),
        CardProduct(id: "halifax-gb-reward", institutionID: "halifax-gb", market: "GB", name: "Reward Credit Card", aliases: ["reward"], network: "Mastercard"),
        CardProduct(id: "halifax-gb-debit", institutionID: "halifax-gb", market: "GB", name: "Halifax Debit Card", network: "Visa", kind: .debit),
        CardProduct(id: "natwest-gb-purchase", institutionID: "natwest-gb", market: "GB", name: "Purchase & Balance Transfer Card", aliases: ["purchase"], network: "Mastercard", publishedFXFeePct: 2.75, sourceURL: "https://www.natwest.com/support-centre/payments/general/what-is-the-foreign-transaction-fee-on-my-credit-card.html", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "natwest-gb-travelreward", institutionID: "natwest-gb", market: "GB", name: "Travel Reward Credit Card", aliases: ["travel reward"], network: "Mastercard", publishedFXFeePct: 0, sourceURL: "https://www.natwest.com/support-centre/payments/general/what-is-the-foreign-transaction-fee-on-my-credit-card.html", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "natwest-gb-debit", institutionID: "natwest-gb", market: "GB", name: "NatWest Debit Card", network: "Visa", kind: .debit),
        CardProduct(id: "santander-gb-edge", institutionID: "santander-gb", market: "GB", name: "Santander Edge Credit Card", aliases: ["edge"], network: "Mastercard"),
        CardProduct(id: "santander-gb-zero", institutionID: "santander-gb", market: "GB", name: "Zero Credit Card", aliases: ["zero"], network: "Mastercard", isActive: false),
        CardProduct(id: "nationwide-gb-member", institutionID: "nationwide-gb", market: "GB", name: "Member Credit Card", aliases: ["member"], network: "Visa"),
        CardProduct(id: "nationwide-gb-debit", institutionID: "nationwide-gb", market: "GB", name: "Nationwide Debit Card", network: "Visa", kind: .debit),
        CardProduct(id: "amex-gb-platinum", institutionID: "amex-gb", market: "GB", name: "The Platinum Card", aliases: ["platinum"], network: "Amex"),
        CardProduct(id: "amex-gb-nectar", institutionID: "amex-gb", market: "GB", name: "Nectar Credit Card", aliases: ["nectar"], network: "Amex"),
        CardProduct(id: "amex-gb-cashback", institutionID: "amex-gb", market: "GB", name: "Platinum Cashback Everyday", aliases: ["cashback"], network: "Amex"),
        // HK depth
        CardProduct(id: "hsbc-hk-pulse", institutionID: "hsbc-hk", market: "HK", name: "Pulse UnionPay Dual Currency Card", aliases: ["pulse"], network: "UnionPay", publishedFXFeePct: 1.0, sourceURL: "https://www.hsbc.com.hk/credit-cards/fees/", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "hsbc-hk-debit", institutionID: "hsbc-hk", market: "HK", name: "HSBC HK Debit Card", network: "Mastercard", kind: .debit),
        CardProduct(id: "hangseng-hk-travelplus", institutionID: "hangseng-hk", market: "HK", name: "Travel+ Visa Signature", aliases: ["travel+"], network: "Visa"),
        CardProduct(id: "sc-hk-asiamiles", institutionID: "sc-hk", market: "HK", name: "Asia Miles Mastercard", aliases: ["asia miles"], network: "Mastercard"),
        CardProduct(id: "boc-hk-dualcurrency", institutionID: "boc-hk", market: "HK", name: "Dual Currency Card", aliases: ["dual currency"], network: "UnionPay"),
        CardProduct(id: "bea-hk-flyerworld", institutionID: "bea-hk", market: "HK", name: "Flyer World Mastercard", aliases: ["flyer world"], network: "Mastercard"),
        CardProduct(id: "citi-hk-octopus", institutionID: "citi-hk", market: "HK", name: "Citi Octopus Card", aliases: ["octopus"], network: "Visa"),
        // SG/CA/AU depth
        CardProduct(id: "dbs-sg-vantage", institutionID: "dbs-sg", market: "SG", name: "DBS Vantage Card", aliases: ["vantage"], network: "Visa"),
        CardProduct(id: "ocbc-sg-titanium", institutionID: "ocbc-sg", market: "SG", name: "Titanium Rewards Card", aliases: ["titanium"], network: "Mastercard"),
        CardProduct(id: "uob-sg-ladys", institutionID: "uob-sg", market: "SG", name: "UOB Lady's Card", aliases: ["lady's"], network: "Mastercard"),
        CardProduct(id: "sc-sg-journey", institutionID: "sc-sg", market: "SG", name: "Journey Credit Card", aliases: ["journey"], network: "Visa"),
        CardProduct(id: "hsbc-sg-revolution", institutionID: "hsbc-sg", market: "SG", name: "Revolution Credit Card", aliases: ["revolution"], network: "Visa"),
        CardProduct(id: "citi-sg-rewards", institutionID: "citi-sg", market: "SG", name: "Citi Rewards Card", aliases: ["rewards"], network: "Mastercard"),
        CardProduct(id: "rbc-ca-westjet", institutionID: "rbc-ca", market: "CA", name: "WestJet RBC World Elite", aliases: ["westjet"], network: "Mastercard"),
        CardProduct(id: "td-ca-cashback", institutionID: "td-ca", market: "CA", name: "TD Cash Back Visa Infinite", aliases: ["cash back"], network: "Visa"),
        CardProduct(id: "scotia-ca-momentum", institutionID: "scotia-ca", market: "CA", name: "Momentum Visa Infinite", aliases: ["momentum"], network: "Visa"),
        CardProduct(id: "bmo-ca-eclipse", institutionID: "bmo-ca", market: "CA", name: "eclipse Visa Infinite", aliases: ["eclipse"], network: "Visa"),
        CardProduct(id: "cibc-ca-dividend", institutionID: "cibc-ca", market: "CA", name: "Dividend Visa Infinite", aliases: ["dividend"], network: "Visa"),
        CardProduct(id: "amex-ca-gold", institutionID: "amex-ca", market: "CA", name: "American Express Gold Rewards", aliases: ["gold"], network: "Amex"),
        CardProduct(id: "cba-au-lowfee", institutionID: "cba-au", market: "AU", name: "Low Fee Credit Card", aliases: ["low fee"], network: "Mastercard"),
        CardProduct(id: "cba-au-smartawards", institutionID: "cba-au", market: "AU", name: "Smart Awards", aliases: ["smart awards"], network: "Mastercard"),
        CardProduct(id: "westpac-au-low", institutionID: "westpac-au", market: "AU", name: "Low Rate Card", aliases: ["low rate"], network: "Mastercard"),
        CardProduct(id: "anz-au-firstfree", institutionID: "anz-au", market: "AU", name: "ANZ First", aliases: ["first"], network: "Visa"),
        CardProduct(id: "nab-au-lowrate", institutionID: "nab-au", market: "AU", name: "NAB Low Rate Card", aliases: ["low rate"], network: "Visa"),
        // Lineup depth — EU/JP/KR/TW/NZ/AE/neobank majors (well-known
        // product names only; fee data stays unverified-nil).
        CardProduct(id: "monzo-gb-flex", institutionID: "monzo-gb", market: "GB", name: "Monzo Flex", aliases: ["flex"], network: "Mastercard", publishedFXFeePct: 0, sourceURL: "https://monzo.com/ecb-rates", lastVerifiedAt: "2026-07-13"),
        CardProduct(id: "abn-nl-credit", institutionID: "abn-nl", market: "NL", name: "ABN AMRO Credit Card", network: "Mastercard"),
        CardProduct(id: "abn-nl-debit", institutionID: "abn-nl", market: "NL", name: "ABN AMRO Debit Card", network: "Maestro", kind: .debit),
        CardProduct(id: "ing-nl-credit", institutionID: "ing-nl", market: "NL", name: "ING Creditcard", network: "Visa"),
        CardProduct(id: "rabo-nl-debit", institutionID: "rabo-nl", market: "NL", name: "Rabobank Debit Card", network: "Maestro", kind: .debit),
        CardProduct(id: "deutsche-de-classic", institutionID: "deutsche-de", market: "DE", name: "Mastercard Classic", aliases: ["classic"], network: "Mastercard"),
        CardProduct(id: "deutsche-de-gold", institutionID: "deutsche-de", market: "DE", name: "Mastercard Gold", aliases: ["gold"], network: "Mastercard"),
        CardProduct(id: "n26-de-you", institutionID: "n26-de", market: "DE", name: "N26 You Debit", aliases: ["you"], network: "Mastercard", kind: .debit),
        CardProduct(id: "bnp-fr-classic", institutionID: "bnp-fr", market: "FR", name: "Visa Classic", aliases: ["classic"], network: "Visa"),
        CardProduct(id: "santander-es-zero", institutionID: "santander-es", market: "ES", name: "Tarjeta Zero", aliases: ["zero"], network: "Mastercard"),
        CardProduct(id: "santander-es-debito", institutionID: "santander-es", market: "ES", name: "Santander Débito", network: "Mastercard", kind: .debit),
        CardProduct(id: "bbva-es-debito", institutionID: "bbva-es", market: "ES", name: "Aqua Débito", network: "Visa", kind: .debit),
        CardProduct(id: "unicredit-it-flexia", institutionID: "unicredit-it", market: "IT", name: "UniCreditCard Flexia", aliases: ["flexia"], network: "Visa"),
        CardProduct(id: "unicredit-it-genius", institutionID: "unicredit-it", market: "IT", name: "Genius Card", aliases: ["genius"], network: "Mastercard", kind: .debit),
        CardProduct(id: "intesa-it-debit", institutionID: "intesa-it", market: "IT", name: "XME Card Debit", network: "Mastercard", kind: .debit),
        CardProduct(id: "mufg-jp-card", institutionID: "mufg-jp", market: "JP", name: "MUFG Card", network: "Visa"),
        CardProduct(id: "mufg-jp-gold", institutionID: "mufg-jp", market: "JP", name: "MUFG Card Gold", aliases: ["gold"], network: "Visa"),
        CardProduct(id: "smbc-jp-olive", institutionID: "smbc-jp", market: "JP", name: "Olive", aliases: ["olive"], network: "Visa", kind: .debit),
        CardProduct(id: "rakuten-jp-gold", institutionID: "rakuten-jp", market: "JP", name: "Rakuten Gold Card", aliases: ["gold"], network: "Visa"),
        CardProduct(id: "kb-kr-wesh", institutionID: "kb-kr", market: "KR", name: "KB My WE:SH Card", aliases: ["wesh", "we:sh"], network: "Visa"),
        CardProduct(id: "shinhan-kr-mrlife", institutionID: "shinhan-kr", market: "KR", name: "Shinhan Mr.Life", aliases: ["mr.life"], network: "Visa"),
        CardProduct(id: "ctbc-tw-linepay", institutionID: "ctbc-tw", market: "TW", name: "LINE Pay Card", aliases: ["line pay"], network: "Visa"),
        CardProduct(id: "cathay-tw-cathaypacific", institutionID: "cathay-tw", market: "TW", name: "Cathay Pacific Co-brand Card", aliases: ["cathay pacific"], network: "Visa"),
        CardProduct(id: "anz-nz-lowrate", institutionID: "anz-nz", market: "NZ", name: "ANZ Low Rate Visa", aliases: ["low rate"], network: "Visa"),
        CardProduct(id: "asb-nz-debit", institutionID: "asb-nz", market: "NZ", name: "ASB Visa Debit", network: "Visa", kind: .debit),
        CardProduct(id: "enbd-ae-titanium", institutionID: "enbd-ae", market: "AE", name: "Titanium Credit Card", aliases: ["titanium"], network: "Mastercard"),
        CardProduct(id: "fab-ae-etihad", institutionID: "fab-ae", market: "AE", name: "Etihad Guest Signature", aliases: ["etihad"], network: "Visa"),
        // International
        CardProduct(id: "wise-intl-card", institutionID: "wise-intl", market: "INTL", name: "Wise Card", network: "Visa", kind: .debit),
        CardProduct(id: "revolut-intl-standard", institutionID: "revolut-intl", market: "INTL", name: "Revolut Card", network: "Visa", kind: .debit),
    ]
}
