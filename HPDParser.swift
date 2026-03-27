//
//  HPDParser.swift
//  Kbuck
//
//  Parses raw HTML/text from the HPD Auction page into [HPDEntry].
//

import Foundation

struct HPDParser {

    // MARK: - Compiled Regexes (created once, reused)

    static let dateRegex: NSRegularExpression = try! NSRegularExpression(pattern: #"^\d{1,2}/\d{1,2}/\d{2,4}$"#)
    static let timeRegex: NSRegularExpression = try! NSRegularExpression(pattern: "^\\d{1,2}:\\d{2}(?::\\d{2})?\\s*(AM|PM)$", options: [.caseInsensitive])
    static let vinRegex:  NSRegularExpression = try! NSRegularExpression(pattern: "^[A-HJ-NPR-Z0-9]{8,17}$")
    private static let dateFindRegex: NSRegularExpression = try! NSRegularExpression(pattern: #"(\d{1,2})/(\d{1,2})/(\d{2,4})"#)

    // MARK: - Line classifiers

    static func isDateLine(_ s: String) -> Bool {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: s.utf16.count)
        return dateRegex.firstMatch(in: s, options: [], range: range) != nil
    }

    static func isTimeLine(_ s: String) -> Bool {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: s.utf16.count)
        return timeRegex.firstMatch(in: s, options: [], range: range) != nil
    }

    static func isVINLine(_ s: String) -> Bool {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: s.utf16.count)
        return vinRegex.firstMatch(in: s, options: [], range: range) != nil
    }

    /// More tolerant VIN detector: at least 8 alphanumeric characters.
    static func isLikelyVIN(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8 else { return false }
        return t.range(of: "^[A-Za-z0-9]{8,}$", options: .regularExpression) != nil
    }

    static func isPlausibleYear(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 2 || t.count == 4, let n = Int(t) else { return false }
        if t.count == 2 { return (0...99).contains(n) }
        return (1900...2100).contains(n)
    }

    /// Returns canonical MM/dd/yyyy if a US numeric date is found; otherwise nil.
    static func normalizeUSDate(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = t as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = dateFindRegex.firstMatch(in: t, options: [], range: range),
              m.numberOfRanges >= 4 else { return nil }
        let mmStr = ns.substring(with: m.range(at: 1))
        let ddStr = ns.substring(with: m.range(at: 2))
        let yyStr = ns.substring(with: m.range(at: 3))
        guard let mm = Int(mmStr), let dd = Int(ddStr) else { return nil }
        var yyyy: Int
        if let y = Int(yyStr) {
            if y < 100 { yyyy = (y <= 24) ? (2000 + y) : (1900 + y) } else { yyyy = y }
        } else { return nil }
        guard (1...12).contains(mm) && (1...31).contains(dd) && (1900...2100).contains(yyyy) else { return nil }
        return String(format: "%02d/%02d/%04d", mm, dd, yyyy)
    }

    // MARK: - HTML helpers

    private static func stripTags(_ html: String) -> String {
        var s = html
        let brRegex = try! NSRegularExpression(pattern: "<br\\s*/?>", options: [.caseInsensitive])
        let full = NSRange(location: 0, length: (s as NSString).length)
        s = brRegex.stringByReplacingMatches(in: s, options: [], range: full, withTemplate: "\n")
        let regex = try! NSRegularExpression(pattern: "<[^>]+>", options: [.dotMatchesLineSeparators])
        let range = NSRange(location: 0, length: s.utf16.count)
        s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML table parser

    private static func parseHTML(_ raw: String) -> [HPDEntry] {
        func norm(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        func canonicalHeader(_ s: String) -> String? {
            let t = norm(s)
            if (t.contains("date") && t.contains("scheduled")) || t == "date" || t.contains("auction date") || t.contains("date/time") || t.contains("schedule date") || t.contains("scheduled date") { return "date scheduled" }
            if t == "time" || t.contains("time") || t.contains("start time") || t.contains("begin time") || t.contains("auction time") || t.contains("estimated start time") { return "time" }
            if t.contains("storage") && t.contains("name") { return "storage lot name" }
            if (t.contains("lot") && t.contains("name")) || (t.contains("location") && t.contains("name")) { return "storage lot name" }
            if t.contains("storage") && t.contains("address") { return "storage lot address" }
            if t.contains("address") || t.contains("location address") || (t.contains("location") && t.contains("address")) { return "storage lot address" }
            if t == "year" || t.hasSuffix(" year") { return "year" }
            if t == "make" || t.hasSuffix(" make") { return "make" }
            if t == "model" || t.hasSuffix(" model") { return "model" }
            if t == "vin" || t.contains("vin") { return "vin" }
            if t == "plate" || t.contains("plate") || t.contains("tag") { return "plate" }
            return nil
        }

        let rowRegex = try! NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: [.dotMatchesLineSeparators, .caseInsensitive])
        let cellRegex = try! NSRegularExpression(pattern: "<t[dh][^>]*>(.*?)</t[dh]>", options: [.dotMatchesLineSeparators, .caseInsensitive])
        let ns = raw as NSString
        let rowMatches = rowRegex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))

        var headerIndex: [String: Int] = [:]
        var entries: [HPDEntry] = []

        for rm in rowMatches {
            let rowInner = ns.substring(with: rm.range(at: 1))
            let rowNS = rowInner as NSString
            let cms = cellRegex.matches(in: rowInner, options: [], range: NSRange(location: 0, length: rowNS.length))
            if cms.isEmpty { continue }
            var cells: [String] = []
            for cm in cms { cells.append(stripTags(rowNS.substring(with: cm.range(at: 1)))) }

            if headerIndex.isEmpty {
                var tempMap: [String: Int] = [:]
                for (i, label) in cells.enumerated() {
                    if let key = canonicalHeader(label) { tempMap[key] = i }
                }
                let core = ["year", "make", "model", "vin"]
                if core.allSatisfy({ tempMap[$0] != nil }) {
                    headerIndex = tempMap
                    continue
                }
            }

            if cells.count == 1, norm(cells[0]).hasPrefix("vehicles scheduled for auction") { continue }

            func val(_ key: String) -> String? {
                if let idx = headerIndex[key], idx < cells.count { return cells[idx] }
                return nil
            }

            if !headerIndex.isEmpty {
                var rawDate = val("date scheduled") ?? ""
                if rawDate.isEmpty, let found = cells.first(where: { normalizeUSDate($0) != nil }) { rawDate = found }
                var time = val("time")
                if time == nil || (time ?? "").isEmpty, let foundTime = cells.first(where: { isTimeLine($0) }) { time = foundTime }
                let lotName = val("storage lot name") ?? ""
                let lotAddr = val("storage lot address") ?? ""
                var year = val("year") ?? ""
                var make = val("make") ?? ""
                var model = val("model") ?? ""
                let vin = val("vin") ?? ""
                let plate = val("plate") ?? ""

                func hasZip(_ s: String) -> Bool { s.range(of: #"\b\d{5}(?:-\d{4})?\b"#, options: .regularExpression) != nil }
                func hasStreetNo(_ s: String) -> Bool { s.range(of: #"\b\d{1,5}\s+"#, options: .regularExpression) != nil }
                let lotNameFixed = lotName
                var lotAddrFixed = lotAddr
                let addrLines = lotAddrFixed.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{00A0}", with: " ").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if addrLines.count > 1 {
                    if let best = addrLines.first(where: { hasZip($0) || hasStreetNo($0) }) { lotAddrFixed = best } else { lotAddrFixed = addrLines.joined(separator: " ") }
                }
                do {
                    let lower = lotAddrFixed.lowercased()
                    let hasAnyDigit = lower.range(of: "\\d", options: .regularExpression) != nil
                    let hasZipLike = hasZip(lotAddrFixed)
                    let hasStreetCues = hasStreetNo(lotAddrFixed) || (lower.range(of: #"\b(st|ave|rd|dr|blvd|ln|lane|way|pkwy|parkway|court|ct|cir|circle|trl|trail|hwy|highway|suite|ste)\b"#, options: .regularExpression) != nil)
                    let looksBusiness = lower.contains(" inc") || lower.contains(" inc.") || lower.contains(" llc") || lower.contains(" llc.") || lower.contains(" co ") || lower.contains(" company") || lower.contains(" towing") || lower.contains(" storage") || lower.contains(" motors") || lower.contains(" auto ")
                    if looksBusiness && !(hasStreetCues || hasZipLike || hasAnyDigit) { lotAddrFixed = "" }
                }

                func plausibleYear(_ s: String) -> Bool {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    let c = t.count
                    guard c == 2 || c == 4 else { return false }
                    return Int(t) != nil
                }
                if !plausibleYear(year), let vinIdx = headerIndex["vin"], vinIdx < cells.count {
                    var yIndex: Int? = nil; var p = vinIdx - 1
                    while p >= 0 { let cand = cells[p].trimmingCharacters(in: .whitespacesAndNewlines); if isPlausibleYear(cand) { yIndex = p; break }; if p < 0 { break }; p -= 1 }
                    if let yi = yIndex { year = cells[yi]; if yi + 1 < vinIdx { make = cells[yi + 1] }; if yi + 2 < vinIdx { model = cells[yi + 2] } } else { let yIdx = vinIdx - 3; let mkIdx = vinIdx - 2; let mdIdx = vinIdx - 1; if yIdx >= 0 && yIdx < cells.count { year = cells[yIdx] }; if mkIdx >= 0 && mkIdx < cells.count { make = cells[mkIdx] }; if mdIdx >= 0 && mdIdx < cells.count { model = cells[mdIdx] } }
                }
                if (year.isEmpty || make.isEmpty || model.isEmpty), let vinIdx = headerIndex["vin"], vinIdx < cells.count {
                    var yIndex: Int? = nil; var p = vinIdx - 1
                    while p >= 0 { let cand = cells[p].trimmingCharacters(in: .whitespacesAndNewlines); if isPlausibleYear(cand) { yIndex = p; break }; if p < 0 { break }; p -= 1 }
                    if let yi = yIndex { if year.isEmpty { year = cells[yi] }; if make.isEmpty && yi + 1 < vinIdx { make = cells[yi + 1] }; if model.isEmpty && yi + 2 < vinIdx { model = cells[yi + 2] } } else { let yIdx = vinIdx - 3; let mkIdx = vinIdx - 2; let mdIdx = vinIdx - 1; if year.isEmpty && yIdx >= 0 && yIdx < cells.count { year = cells[yIdx] }; if make.isEmpty && mkIdx >= 0 && mkIdx < cells.count { make = cells[mkIdx] }; if model.isEmpty && mdIdx >= 0 && mdIdx < cells.count { model = cells[mdIdx] } }
                }
                if let d = normalizeUSDate(rawDate), (isVINLine(vin) || isLikelyVIN(vin)) {
                    entries.append(HPDEntry(dateScheduled: d, time: time, lotName: lotNameFixed, lotAddress: lotAddrFixed, year: year, make: make, model: model, vin: vin, plate: plate))
                }
                continue
            }

            // Fallback positional parse
            var i = 0
            while i < cells.count {
                let rawDate = cells[i]
                if isDateLine(rawDate) || normalizeUSDate(rawDate) != nil {
                    var idx = i + 1
                    var timeVal: String? = nil
                    if idx < cells.count, isTimeLine(cells[idx]) { timeVal = cells[idx]; idx += 1 }
                    guard idx + 3 < cells.count else { break }
                    let lotName = cells[idx]; let lotAddr = (idx + 1 < cells.count) ? cells[idx + 1] : ""
                    var vinPos: Int? = nil; let searchEnd = min(cells.count - 1, idx + 12); var p = idx + 2
                    while p <= searchEnd { let cand = cells[p]; if isVINLine(cand) || isLikelyVIN(cand) { vinPos = p; break }; p += 1 }
                    guard let v = vinPos, v - 3 >= idx + 2 else { i += 1; continue }
                    var year = ""; var make = ""; var model = ""; var yIndex: Int? = nil; var p2 = v - 1
                    while p2 >= idx { let cand = cells[p2].trimmingCharacters(in: .whitespacesAndNewlines); if isPlausibleYear(cand) { yIndex = p2; break }; p2 -= 1 }
                    if let yi = yIndex { year = cells[yi]; if yi + 1 < v { make = cells[yi + 1] }; if yi + 2 < v { model = cells[yi + 2] } } else { year = (v - 3 >= idx) ? cells[v - 3] : ""; make = (v - 2 >= idx) ? cells[v - 2] : ""; model = (v - 1 >= idx) ? cells[v - 1] : "" }
                    let vin = cells[v]; let plate = (v + 1 < cells.count) ? cells[v + 1] : ""
                    if isVINLine(vin) || isLikelyVIN(vin) {
                        let d = normalizeUSDate(rawDate) ?? rawDate
                        entries.append(HPDEntry(dateScheduled: d, time: timeVal, lotName: lotName, lotAddress: lotAddr, year: year, make: make, model: model, vin: vin, plate: plate))
                    }
                    i = v + 2
                } else { i += 1 }
            }
        }
        return entries
    }

    // MARK: - Plain text parser

    private static func parsePlain(_ raw: String) -> [HPDEntry] {
        var entries: [HPDEntry] = []
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let skipSet: Set<String> = ["Vehicles Scheduled For Auction", "Vehicles Scheduled For Auction 10/20/2025", "Date Scheduled", "Storage Lot Name", "Storage Lot Address", "Year", "Make", "Model", "VIN", "Plate", "Time"]
        func shouldSkip(_ s: String) -> Bool { skipSet.contains(s) || s.hasPrefix("Vehicles Scheduled For Auction") }

        var i = 0; var currentDate = ""; var currentTime: String? = nil; var currentLotName = ""; var currentLotAddress = ""
        while i < lines.count {
            let line = lines[i]
            if shouldSkip(line) { i += 1; continue }
            if isDateLine(line) || normalizeUSDate(line) != nil {
                currentDate = normalizeUSDate(line) ?? line; var k = i + 1; currentTime = nil
                if k < lines.count, isTimeLine(lines[k]) { currentTime = lines[k]; k += 1 }
                currentLotName = (k < lines.count) ? lines[k] : ""
                currentLotAddress = (k + 1 < lines.count) ? lines[k + 1] : ""
                i = k + 2; continue
            }
            var yi = i
            while yi < lines.count { let t = lines[yi]; if isDateLine(t) || isTimeLine(t) || isVINLine(t) || isLikelyVIN(t) { break }; if isPlausibleYear(t) { break }; yi += 1 }
            let year = (yi < lines.count && isPlausibleYear(lines[yi])) ? lines[yi] : lines[i]
            let make = (yi + 1 < lines.count) ? lines[yi + 1] : ""
            var j = yi + 2; var modelParts: [String] = []
            while j < lines.count { let t = lines[j]; if isDateLine(t) || isTimeLine(t) || isVINLine(t) || isLikelyVIN(t) || isPlausibleYear(t) { break }; modelParts.append(t); j += 1 }
            let model = modelParts.joined(separator: " ")
            var vin = ""; if j < lines.count, (isVINLine(lines[j]) || isLikelyVIN(lines[j])) { vin = lines[j]; j += 1 }
            var plate = ""; if j < lines.count, !isDateLine(lines[j]), !isTimeLine(lines[j]), !(isVINLine(lines[j]) || isLikelyVIN(lines[j])) { plate = lines[j]; j += 1 }
            if !vin.isEmpty { entries.append(HPDEntry(dateScheduled: currentDate, time: currentTime, lotName: currentLotName, lotAddress: currentLotAddress, year: year, make: make, model: model, vin: vin, plate: plate)) }
            i = j
        }
        return entries
    }

    // MARK: - Public entry point

    static func parse(_ raw: String) -> [HPDEntry] {
        let htmlEntries = parseHTML(raw)
        if !htmlEntries.isEmpty { return htmlEntries }
        let textOnly = stripTags(raw)
        let plain = parsePlain(textOnly)
        if !plain.isEmpty { return plain }
        return parsePlain(raw)
    }
}
