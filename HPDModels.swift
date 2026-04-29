//
//  HPDModels.swift
//  Kbuck
//

import Foundation

// MARK: - HPD Entry

enum AuctionSource: String, Codable, CaseIterable, Identifiable, Hashable {
    case hpd
    case sheriffAuction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hpd:
            return "HPD Auction"
        case .sheriffAuction:
            return "Sheriff Auction"
        }
    }

    var shortLabel: String {
        switch self {
        case .hpd:
            return "HPD"
        case .sheriffAuction:
            return "Sheriff"
        }
    }
}

struct HPDEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    var dateScheduled: String
    var time: String? = nil
    var lotName: String
    var lotAddress: String
    var year: String
    var make: String
    var model: String
    var vin: String
    var plate: String
    var source: AuctionSource = .hpd

    private enum CodingKeys: String, CodingKey {
        case id
        case dateScheduled
        case time
        case lotName
        case lotAddress
        case year
        case make
        case model
        case vin
        case plate
        case source
    }

    init(
        id: UUID = UUID(),
        dateScheduled: String,
        time: String? = nil,
        lotName: String,
        lotAddress: String,
        year: String,
        make: String,
        model: String,
        vin: String,
        plate: String,
        source: AuctionSource = .hpd
    ) {
        self.id = id
        self.dateScheduled = dateScheduled
        self.time = time
        self.lotName = lotName
        self.lotAddress = lotAddress
        self.year = year
        self.make = make
        self.model = model
        self.vin = vin
        self.plate = plate
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateScheduled = try container.decode(String.self, forKey: .dateScheduled)
        time = try container.decodeIfPresent(String.self, forKey: .time)
        lotName = try container.decode(String.self, forKey: .lotName)
        lotAddress = try container.decode(String.self, forKey: .lotAddress)
        year = try container.decode(String.self, forKey: .year)
        make = try container.decode(String.self, forKey: .make)
        model = try container.decode(String.self, forKey: .model)
        vin = try container.decode(String.self, forKey: .vin)
        plate = try container.decode(String.self, forKey: .plate)
        source = try container.decodeIfPresent(AuctionSource.self, forKey: .source) ?? .hpd
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(dateScheduled, forKey: .dateScheduled)
        try container.encodeIfPresent(time, forKey: .time)
        try container.encode(lotName, forKey: .lotName)
        try container.encode(lotAddress, forKey: .lotAddress)
        try container.encode(year, forKey: .year)
        try container.encode(make, forKey: .make)
        try container.encode(model, forKey: .model)
        try container.encode(vin, forKey: .vin)
        try container.encode(plate, forKey: .plate)
        try container.encode(source, forKey: .source)
    }
}

// MARK: - Odometer / Valuation Cache

struct OdoInfo: Codable, Equatable {
    var odometer: String
    var testDate: String
    var privateValue: String?
    var realModel: String? = nil
}

struct LegalAgreementLog: Codable {
    var user_id: UUID?
    var vin: String
    var action: String
}

// MARK: - Thread-safe shared auction date formatter
//
// Allocated exactly once at module load. Every call site that previously created
// a local `DateFormatter` now calls `parseAuctionDate(from:)` instead, reducing
// per-call allocation cost from ~20 µs to effectively zero.

private enum AuctionDateCache {
    static let lock = NSLock()
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yyyy"
        f.locale     = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private enum CompactAuctionTimeCache {
    static let lock = NSLock()
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()
}

// MARK: - Shared Utility Functions

/// Normalizes a VIN to uppercase alphanumeric, excluding I, O, Q per VIN specification.
func normalizeVIN(_ s: String) -> String {
    let allowed = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
    return s.uppercased().filter { allowed.contains($0) }
}

/// Converts 2-digit year strings to 4-digit (≤24 → 2000+, else 1900+).
func normalizedYear(_ raw: String) -> String {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count == 2, let val = Int(t) {
        return val <= 24 ? String(2000 + val) : String(1900 + val)
    }
    return t
}

/// Parses an "MM/dd/yyyy" date string using the module-level shared formatter.
/// Thread-safe via NSLock. Zero allocations after the first call.
func parseAuctionDate(from dateString: String) -> Date? {
    AuctionDateCache.lock.lock()
    defer { AuctionDateCache.lock.unlock() }
    return AuctionDateCache.formatter.date(from: dateString)
}

func parseAuctionDate(_ dateStr: String, timeStr: String?) -> Date? {
    let base = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)
    let time = (timeStr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = .current
    let dateCandidatesWithTime = [
        "MM/dd/yyyy h:mm:ss a", "MM/dd/yyyy h:mm a",
        "MM/dd/yyyy h:mm:ssa", "MM/dd/yyyy h:mma",
        "M/d/yyyy h:mm:ss a", "M/d/yyyy h:mm a",
        "M/d/yyyy h:mm:ssa", "M/d/yyyy h:mma",
        "MM/dd/yy h:mm:ss a", "MM/dd/yy h:mm a",
        "MM/dd/yy h:mm:ssa", "MM/dd/yy h:mma",
        "M/d/yy h:mm:ss a", "M/d/yy h:mm a",
        "M/d/yy h:mm:ssa", "M/d/yy h:mma"
    ]
    if !time.isEmpty {
        for f in dateCandidatesWithTime {
            df.dateFormat = f
            if let d = df.date(from: "\(base) \(time)") { return d }
        }
    }
    let dateOnlyCandidates = ["MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy"]
    for f in dateOnlyCandidates {
        df.dateFormat = f
        if let d = df.date(from: base) { return d }
    }
    return nil
}

extension Date {
    func compactAuctionTime() -> String {
        CompactAuctionTimeCache.lock.lock()
        let raw = CompactAuctionTimeCache.formatter.string(from: self)
        CompactAuctionTimeCache.lock.unlock()
        return raw
            .replacingOccurrences(of: ":00", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

/// Returns true if the auction date falls strictly before today's midnight.
/// Uses the shared formatter — no per-call DateFormatter allocation.
func isDateInPast(_ dateString: String) -> Bool {
    guard let date = parseAuctionDate(from: dateString) else { return false }
    let today = Calendar.current.startOfDay(for: Date())
    return Calendar.current.startOfDay(for: date) < today
}

// MARK: - VIN Failure Tracker

class VINFailureTracker {
    static let shared = VINFailureTracker()
    private let defaults = UserDefaults.standard
    private let key = "hpd_vin_failures"

    private var history: [String: [Date]] {
        get {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([String: [Date]].self, from: data) else { return [:] }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) { defaults.set(encoded, forKey: key) }
        }
    }

    func recordFailure(vin: String) {
        guard !vin.isEmpty else { return }
        var current = history
        var dates = current[vin] ?? []
        dates.append(Date())
        current[vin] = dates
        history = current
    }

    func clearFailures(vin: String) {
        var current = history
        current.removeValue(forKey: vin)
        history = current
    }

    func status(for vin: String) -> (isRed: Bool, canTry: Bool, errorMessage: String?) {
        let dates = history[vin] ?? []
        if dates.isEmpty { return (false, true, nil) }

        if dates.count >= 6 {
            return (true, false, "Extraction permanently blocked for this vehicle. The server consistently returns errors or data does not exist.")
        }

        if dates.count >= 3 {
            guard let lastFailure = dates.last else { return (true, true, nil) }
            let diff = Date().timeIntervalSince(lastFailure)
            if diff < 3600 {
                let minsLeft = Int((3600 - diff) / 60)
                return (true, false, "Too many failed attempts. Please try again in \(minsLeft) minutes.")
            }
        }

        return (true, true, nil)
    }
}

// MARK: - Shared Utility Functions

/// Formats a raw numeric price string for display (e.g., "4200" → "$4,200").
func formatPrivateValueForDisplay(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return "" }
    if t.contains("$") || t.contains(",") { return t }
    let cleaned = t.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
    guard !cleaned.isEmpty, let val = Double(cleaned) else { return t }
    let nf = NumberFormatter()
    nf.numberStyle = .currency
    nf.currencyCode = "USD"
    nf.maximumFractionDigits = 0
    return nf.string(from: NSNumber(value: val)) ?? t
}

/// Maps raw 4-letter database make codes (and full names) to properly
/// capitalised human-readable brand names for display throughout the UI.
func brandDisplayName(for rawMake: String) -> String {
    let m = rawMake.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if m.isEmpty { return rawMake }
    if m.contains("toyota")     || m.hasPrefix("toyo") { return "Toyota" }
    if m.contains("honda")      || m.hasPrefix("hond") { return "Honda" }
    if m.contains("chevrolet")  || m.contains("chevy") || m.hasPrefix("chev") { return "Chevrolet" }
    if m.contains("nissan")     || m.hasPrefix("niss") { return "Nissan" }
    if m.contains("dodge")      || m.hasPrefix("dodg") { return "Dodge" }
    if m.contains("bmw")                               { return "BMW" }
    if m.contains("ford")       || m.hasPrefix("ford") { return "Ford" }
    if m.contains("acura")      || m.hasPrefix("acur") { return "Acura" }
    if m.contains("tesla")      || m.hasPrefix("tesl") { return "Tesla" }
    if m.contains("kia")                               { return "Kia" }
    if m.contains("ram")        || m.hasPrefix("ram")  { return "Ram" }
    if m.contains("gmc")                               { return "GMC" }
    if m.contains("hyundai")    || m.hasPrefix("hyun") { return "Hyundai" }
    if m.contains("volkswagen") || m.hasPrefix("volk") { return "Volkswagen" }
    if m.contains("mercedes")   || m.hasPrefix("merz") { return "Mercedes-Benz" }
    if m.contains("mazda")      || m.hasPrefix("mazd") { return "Mazda" }
    if m.contains("buick")      || m.hasPrefix("buic") { return "Buick" }
    if m.contains("cadillac")   || m.hasPrefix("cadi") { return "Cadillac" }
    if m.contains("isuzu")      || m.hasPrefix("isuz") { return "Isuzu" }
    if m.contains("subaru")     || m.hasPrefix("suba") { return "Subaru" }
    if m.contains("mitsubishi") || m.hasPrefix("mits") { return "Mitsubishi" }
    if m.contains("lexus")      || m.hasPrefix("lexu") { return "Lexus" }
    if m.contains("scion")      || m.hasPrefix("scio") { return "Scion" }
    if m.contains("chrysler")   || m.hasPrefix("chry") { return "Chrysler" }
    if m.contains("jeep")       || m.hasPrefix("jeep") { return "Jeep" }
    if m.contains("infiniti")   || m.hasPrefix("infi") { return "Infiniti" }
    if m.contains("pontiac")    || m.hasPrefix("pont") { return "Pontiac" }
    if m.contains("lincoln")    || m.hasPrefix("linc") { return "Lincoln" }
    if m.contains("suzuki")    || m.hasPrefix("suzi") { return "Suzuki" }
    if m.contains("audi")    || m.hasPrefix("audi") { return "Audi" }
    if m.contains("mercuri")    || m.hasPrefix("merc") { return "Mercuri" }
    if m.contains("saturn")    || m.hasPrefix("satu") { return "Saturn" }
    if m.contains("lincoln")    || m.hasPrefix("linc") { return "Lincoln" }
    if m.contains("porsche")    || m.hasPrefix("pors") { return "Porsche" }
    if m.contains("landrover")    || m.hasPrefix("land") { return "Land-Rover" }
    if m.contains("mini")    || m.hasPrefix("mini") { return "Mini-Cooper" }
    if m.contains("hummer")    || m.hasPrefix("humm") { return "Hummer" }
    if m.contains("fiat")    || m.hasPrefix("fiat") { return "Fiat" }
    if m.contains("volvo")    || m.hasPrefix("volv") { return "Volvo" }



    return rawMake.capitalized
}

/// Shared brand-to-asset mapper used by HPD and Dashboard views.
func brandAssetName(for rawMake: String) -> String? {
    let m = rawMake.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if m.isEmpty { return nil }
    if m.contains("toyota")     || m.hasPrefix("toyo") { return "toyo" }
    if m.contains("honda")      || m.hasPrefix("hond") { return "hond" }
    if m.contains("chevrolet")  || m.contains("chevy") || m.hasPrefix("chev") { return "chev" }
    if m.contains("nissan")     || m.hasPrefix("niss") { return "niss" }
    if m.contains("dodge")      || m.hasPrefix("dodg") { return "dodg" }
    if m.contains("bmw")                               { return "bmw"  }
    if m.contains("ford")       || m.hasPrefix("ford") { return "ford" }
    if m.contains("acura")      || m.hasPrefix("acur") { return "acur" }
    if m.contains("tesla")      || m.hasPrefix("tesl") { return "tesl" }
    if m.contains("kia")                               { return "kia"  }
    if m.contains("ram")        || m.hasPrefix("ram")  { return "ram"  }
    if m.contains("gmc")                               { return "gmc"  }
    if m.contains("hyundai")    || m.hasPrefix("hyun") { return "hyun" }
    if m.contains("volkswagen") || m.hasPrefix("volk") { return "volk" }
    if m.contains("mercedes")   || m.hasPrefix("merz") { return "merz" }
    if m.contains("mazda")      || m.hasPrefix("mazd") { return "mazd" }
    if m.contains("buick")      || m.hasPrefix("buic") { return "buic" }
    if m.contains("cadillac")   || m.hasPrefix("cadi") { return "cadi" }
    if m.contains("isuzu")      || m.hasPrefix("isuz") { return "isuz" }
    if m.contains("subaru")     || m.hasPrefix("suba") { return "suba" }
    if m.contains("mitsubishi") || m.hasPrefix("mits") { return "mits" }
    if m.contains("lexus")      || m.hasPrefix("lexu") { return "lexu" }
    if m.contains("scion")      || m.hasPrefix("scio") { return "scio" }
    if m.contains("chrysler")   || m.hasPrefix("chry") { return "chry" }
    if m.contains("jeep")       || m.hasPrefix("jeep") { return "jeep" }
    if m.contains("infiniti")   || m.hasPrefix("infi") { return "infi" }
    if m.contains("pontiac")    || m.hasPrefix("pont") { return "pont" }
    if m.contains("lincoln")    || m.hasPrefix("linc") { return "linc" }
    if m.contains("suzuki")    || m.hasPrefix("suzi") { return "suzi" }
    if m.contains("audi")    || m.hasPrefix("audi") { return "audi" }
    if m.contains("mercuri")    || m.hasPrefix("merc") { return "merc" }
    if m.contains("saturn")    || m.hasPrefix("satu") { return "satu" }
    if m.contains("lincoln")    || m.hasPrefix("linc") { return "linc" }
    if m.contains("porsche")    || m.hasPrefix("pors") { return "pors" }
    if m.contains("landrover")    || m.hasPrefix("land") { return "land" }
    if m.contains("mini-cooper")    || m.hasPrefix("mini") { return "mini" }
    if m.contains("hummer")    || m.hasPrefix("humm") { return "humm" }
    if m.contains("fiat")    || m.hasPrefix("fiat") { return "fiat" }
    if m.contains("volvo")    || m.hasPrefix("volv") { return "volv" }


    return nil
}

func normalizedModelName(for rawModel: String, make rawMake: String) -> String {
    let make = rawMake.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = model.lowercased()

    guard !code.isEmpty else { return rawModel }

    if make.contains("nissan") || make.hasPrefix("niss") {
        switch code {
        case "versa", "vers":
            return "Versa"
        case "sent", "sentr", "sentra":
            return "Sentra"
        case "alti", "altima":
            return "Altima"
        case "maxi", "maxima":
            return "Maxima"
        case "rogu", "rogue":
            return "Rogue"
        case "mura", "murano":
            return "Murano"
        case "path", "pathfinder":
            return "Pathfinder"
        case "fron", "front", "frontier":
            return "Frontier"
        case "tita", "titan":
            return "Titan"
        case "armd", "armada":
            return "Armada"
        default:
            break
        }
    }

    if make.contains("toyota") || make.hasPrefix("toyo") {
        switch code {
        case "coro", "corol", "corolla":
            return "Corolla"
        case "camr", "camry":
            return "Camry"
        case "rav4", "rav":
            return "RAV4"
        case "taco", "tacom", "tacoma":
            return "Tacoma"
        case "tund", "tundra":
            return "Tundra"
        case "4run", "4runner":
            return "4Runner"
        default:
            break
        }
    }

    if make.contains("honda") || make.hasPrefix("hond") {
        switch code {
        case "civi", "civic":
            return "Civic"
        case "acco", "accord":
            return "Accord"
        case "crv", "cr-v":
            return "CR-V"
        case "odys", "odyssey":
            return "Odyssey"
        case "pilo", "pilot":
            return "Pilot"
        default:
            break
        }
    }

    if make.contains("ford") || make.hasPrefix("ford") {
        switch code {
        case "f150", "f-150":
            return "F-150"
        case "expl", "explo", "explorer":
            return "Explorer"
        case "must", "musta", "mustang":
            return "Mustang"
        case "edge":
            return "Edge"
        default:
            break
        }
    }

    if make.contains("chevrolet") || make.contains("chevy") || make.hasPrefix("chev") {
        switch code {
        case "silv", "silve", "silverado":
            return "Silverado"
        case "mali", "malib", "malibu":
            return "Malibu"
        case "equi", "equin", "equinox":
            return "Equinox"
        case "taho", "tahoe":
            return "Tahoe"
        default:
            break
        }
    }

    return model.capitalized
}

func normalizedSearchTerm(_ text: String) -> String {
    text
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

func decodeAuctionEntries(_ data: Data) -> [HPDEntry] {
    (try? JSONDecoder().decode([HPDEntry].self, from: data)) ?? []
}

func encodeAuctionEntries(_ entries: [HPDEntry]) -> Data {
    (try? JSONEncoder().encode(entries)) ?? Data()
}

func mergedAuctionEntries(_ groups: [HPDEntry]...) -> [HPDEntry] {
    var seen: Set<String> = []
    var merged: [HPDEntry] = []

    for entry in groups.flatMap({ $0 }) {
        let key = [
            entry.source.rawValue,
            normalizedYear(entry.year),
            normalizeVIN(entry.vin),
            entry.dateScheduled.trimmingCharacters(in: .whitespacesAndNewlines),
            entry.lotAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            entry.lotName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "|")

        if seen.insert(key).inserted {
            merged.append(entry)
        }
    }

    return merged
}

func vehicleMatchesSearch(_ query: String, entry: HPDEntry, odoInfo: OdoInfo? = nil) -> Bool {
    let normalizedQuery = normalizedSearchTerm(query)
    guard !normalizedQuery.isEmpty else { return true }

    let tokens = normalizedQuery
        .split(separator: " ")
        .map(String.init)
        .filter { !$0.isEmpty }

    let makeDisplay = brandDisplayName(for: entry.make)
    let realModel = odoInfo?.realModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let normalizedModel = normalizedModelName(for: entry.model, make: entry.make)
    let normalizedVehicleTitle = "\(normalizedYear(entry.year)) \(makeDisplay) \(normalizedModel)"
    let searchableFields = [
        entry.vin,
        normalizedYear(entry.year),
        entry.make,
        makeDisplay,
        entry.model,
        normalizedModel,
        realModel,
        normalizedVehicleTitle,
        entry.lotName,
        entry.lotAddress,
        entry.dateScheduled
    ]
        .map(normalizedSearchTerm)
        .filter { !$0.isEmpty }

    return tokens.allSatisfy { token in
        searchableFields.contains { $0.contains(token) }
    }
}
