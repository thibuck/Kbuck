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
