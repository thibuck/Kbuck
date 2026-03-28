import SwiftUI

// MARK: - Data models

private struct LocationEntry: Identifiable {
    let id       = UUID()
    let location: String
    let count:    Int
    let makes:    [(make: String, count: Int)]   // sorted by count desc
}

private struct DateCard: Identifiable {
    let id        = UUID()
    let date:     String
    let dateObj:  Date
    let locations: [LocationEntry]               // sorted by count desc
}

// MARK: - View

struct HomeSummaryView: View {

    @Binding var selectedTab: Int
    @Binding var targetLocationFilter: String?

    @AppStorage("hpdCachedEntries") private var hpdCachedEntriesData: Data = Data()

    // MARK: - Raw entries

    private var entries: [HPDEntry] {
        guard !hpdCachedEntriesData.isEmpty,
              let decoded = try? JSONDecoder().decode([HPDEntry].self, from: hpdCachedEntriesData)
        else { return [] }
        return decoded
    }

    // MARK: - Collapse state

    @State private var expandedDates: Set<String> = []

    // MARK: - Address normalisation (mirrors HPDView.sanitizedAddressForMaps + streetNumberKey)

    private func normalizeAddress(_ raw: String) -> String {
        var t = raw
            .replacingOccurrences(of: "*",        with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\n",       with: " ")
            .replacingOccurrences(of: "\\s+",    with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard t.count >= 5 else { return "" }

        let lower = t.lowercased()
        let hasDigit  = t.range(of: "\\d", options: .regularExpression) != nil
        let hasZip    = t.range(of: #"\b\d{5}(?:-\d{4})?\b"#, options: .regularExpression) != nil
        let hasStreet = lower.range(of: #"\b(st|ave|rd|dr|blvd|ln|lane|way|pkwy|parkway|court|ct|cir|circle|trl|trail|hwy|highway|suite|ste)\b"#,
                                    options: .regularExpression) != nil
        let looksBiz  = lower.contains(" llc") || lower.contains(" inc") ||
                        lower.contains(" towing") || lower.contains(" storage") ||
                        lower.contains(" motors") || lower.contains(" auto ")
        if looksBiz && !(hasStreet || hasZip || hasDigit) { return "" }
        if !(hasStreet || hasZip || hasDigit)             { return "" }

        for marker in [" houston", " tx ", ", tx", " texas"] {
            if let r = lower.range(of: marker) {
                t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if let r = t.range(of: #"\s*\b\d{5}(?:-\d{4})?\b\s*$"#, options: .regularExpression) {
            t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    private func streetKey(_ s: String) -> String {
        s.components(separatedBy: CharacterSet.decimalDigits.inverted)
         .first { !$0.isEmpty } ?? s.uppercased()
    }

    // MARK: - Brand asset (mirrors HPDView.brandAssetName)

    private func brandAssetName(for rawMake: String) -> String? {
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

    // MARK: - Grouped summaries (Date-primary)
    //
    // Single O(n) pass. Primary sort: chronological (soonest first).
    // Secondary sort: locations by vehicle count desc.

    private var groupedByDate: [DateCard] {
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MM/dd/yyyy"
            f.locale     = Locale(identifier: "en_US_POSIX")
            return f
        }()

        var dateMap:  [String: [String: [String: Int]]] = [:]
        var labelMap: [String: String]                  = [:]

        for entry in entries {
            // Mirror HPDView: skip entries whose auction date has already passed
            guard !isDateInPast(entry.dateScheduled) else { continue }
            let date  = entry.dateScheduled.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = normalizeAddress(entry.lotAddress)
            guard !date.isEmpty, !clean.isEmpty else { continue }

            let skey    = streetKey(clean)
            let makeRaw = entry.make.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let makeKey = makeRaw.isEmpty ? "UNKNOWN" : makeRaw

            if let existing = labelMap[skey] {
                if clean.count < existing.count { labelMap[skey] = clean }
            } else {
                labelMap[skey] = clean
            }

            dateMap[date, default: [:]][skey, default: [:]][makeKey, default: 0] += 1
        }

        return dateMap
            .compactMap { dateStr, locMap -> DateCard? in
                guard let dateObj = fmt.date(from: dateStr) else { return nil }

                let locations: [LocationEntry] = locMap
                    .compactMap { skey, makeHistogram -> LocationEntry? in
                        guard let label = labelMap[skey] else { return nil }
                        let total = makeHistogram.values.reduce(0, +)
                        let makes = makeHistogram
                            .sorted { $0.value > $1.value }
                            .map { (make: $0.key, count: $0.value) }
                        return LocationEntry(location: label, count: total, makes: makes)
                    }
                    .sorted { $0.count > $1.count }

                return DateCard(date: dateStr, dateObj: dateObj, locations: locations)
            }
            .sorted { $0.dateObj < $1.dateObj }
    }

    // MARK: - Active vehicle count (excludes past dates and invalid addresses)

    private var activeVehicleCount: Int {
        groupedByDate.reduce(0) { $0 + $1.locations.reduce(0) { $0 + $1.count } }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                if groupedByDate.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(groupedByDate) { card in
                                dateCard(card)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.xaxis")
                            .foregroundColor(.accentColor)
                            .font(.headline)
                        Text("Dashboard (\(activeVehicleCount))")
                            .font(.headline.bold())
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    // MARK: - Apple Wallet-style collapsible date card

    @ViewBuilder
    private func dateCard(_ card: DateCard) -> some View {
        let isExpanded = expandedDates.contains(card.date)
        let totalForDate = card.locations.reduce(0) { $0 + $1.count }

        VStack(alignment: .leading, spacing: 0) {
            // ── Collapsible header — tap to expand/collapse ───────────
            Button {
                if isExpanded {
                    expandedDates.remove(card.date)
                } else {
                    expandedDates.insert(card.date)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .foregroundColor(.accentColor)
                        .font(.title3)
                    Text(card.date)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(totalForDate) total")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            // ── Expandable location rows ──────────────────────────────
            if isExpanded {
                Divider().padding(.top, 12)

                ForEach(card.locations) { locEntry in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            targetLocationFilter = locEntry.location
                            selectedTab = 1
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundColor(.accentColor)
                                    .font(.subheadline)
                                    .padding(.top, 2)
                                Text(locEntry.location)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer()
                                Text("\(locEntry.count) vehicle\(locEntry.count == 1 ? "" : "s")")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.1))
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                        .buttonStyle(.plain)

                        DisclosureGroup("View Brands") {
                            VStack(spacing: 6) {
                                ForEach(locEntry.makes, id: \.make) { makeEntry in
                                    HStack(spacing: 8) {
                                        if let asset = brandAssetName(for: makeEntry.make),
                                           let img = UIImage(named: asset) {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 20, height: 20)
                                        } else {
                                            Image(systemName: "car.fill")
                                                .frame(width: 20, height: 20)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(makeEntry.make)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(makeEntry.count)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.leading, 4)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption)
                        .tint(.accentColor)
                    }
                    .padding(.top, 12)

                    if locEntry.id != card.locations.last?.id {
                        Divider().padding(.top, 4)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.primary.opacity(0.1), radius: 10, x: 0, y: 5)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "car.2.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Data Available")
                .font(.title3.bold())
            Text("Fetch auction data from the HPD tab to populate the dashboard.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
