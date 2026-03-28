//
//  HPDModels.swift
//  Kbuck
//

import Foundation

// MARK: - HPD Entry

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
}

// MARK: - Odometer / Valuation Cache

struct OdoInfo: Codable, Equatable {
    var odometer: String
    var testDate: String
    var privateValue: String?
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
    return nil
}
