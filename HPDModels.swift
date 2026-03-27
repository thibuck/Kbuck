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

func isDateInPast(_ dateString: String) -> Bool {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM/dd/yyyy"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    guard let date = formatter.date(from: dateString) else { return false }
    return Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
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
