import SwiftUI

// MARK: - Data models

private struct LocationEntry: Identifiable {
    let id       = UUID()
    let location: String
    let vehicles: [HPDEntry]
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
    @AppStorage("hpdRefreshTrigger") private var hpdRefreshTrigger: Int = 0
    @State private var cachedGroupedSummaries: [DateCard] = []
    @State private var cachedActiveVehicleCount: Int = 0

    // MARK: - Collapse state

    @State private var expandedDates: Set<String> = []

    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager
    @AppStorage("userRole") private var userRole: String = "user"
    @State private var showQuotaSheet: Bool = false

    private var currentTierKey: String {
        supabaseService.currentProfile?.plan_tier?.lowercased() ?? storeManager.activeSubscriptionTier.tierKey
    }

    private var toolbarTierKey: String? {
        guard let rawTier = supabaseService.currentTier else { return nil }
        let normalized = rawTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized != "loading" else { return nil }
        return normalized
    }

    private var currentTierDisplayName: String {
        currentTierKey.capitalized
    }

    private var currentTierLimit: Int {
        if let remoteLimit = supabaseService.tierConfigs[currentTierKey]?.daily_fetch_limit {
            return remoteLimit
        }

        switch currentTierKey {
        case "silver":
            return 10
        case "gold":
            return 30
        case "platinum":
            return 200
        default:
            return 3
        }
    }

    // MARK: - Address normalisation (mirrors HPDView.sanitizedAddressForMaps + streetNumberKey)

    private static func normalizeAddress(_ raw: String) -> String {
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

    private static func streetKey(_ s: String) -> String {
        s.components(separatedBy: CharacterSet.decimalDigits.inverted)
         .first { !$0.isEmpty } ?? s.uppercased()
    }

    // MARK: - Grouped summaries (Date-primary)
    //
    // Single O(n) pass. Primary sort: chronological (soonest first).
    // Secondary sort: locations by vehicle count desc.

    private static func buildGroupedSummaries(from entries: [HPDEntry]) -> [DateCard] {
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MM/dd/yyyy"
            f.locale     = Locale(identifier: "en_US_POSIX")
            return f
        }()

        var dateMap:  [String: [String: [String: Int]]] = [:]
        var labelMap: [String: String]                  = [:]
        var vehicleMap: [String: [String: [HPDEntry]]]  = [:]

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
            vehicleMap[date, default: [:]][skey, default: []].append(entry)
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
                        return LocationEntry(
                            location: label,
                            vehicles: vehicleMap[dateStr]?[skey] ?? [],
                            count: total,
                            makes: makes
                        )
                    }
                    .sorted { $0.count > $1.count }

                return DateCard(date: dateStr, dateObj: dateObj, locations: locations)
            }
            .sorted { $0.dateObj < $1.dateObj }
    }

    private func defaultExpandedDate(from grouped: [DateCard]) -> String? {
        guard !grouped.isEmpty else { return nil }

        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let noonToday = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: todayStart) ?? todayStart
        let minimumPreferredDate = now >= noonToday
            ? (calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart)
            : todayStart

        if let nearest = grouped.first(where: { calendar.startOfDay(for: $0.dateObj) >= minimumPreferredDate }) {
            return nearest.date
        }

        return grouped.first?.date
    }
    
    private func recomputeSummaries() {
        guard !hpdCachedEntriesData.isEmpty,
              let decoded = try? JSONDecoder().decode([HPDEntry].self, from: hpdCachedEntriesData)
        else {
            cachedGroupedSummaries = []
            cachedActiveVehicleCount = 0
            expandedDates = []
            return
        }
        let grouped = Self.buildGroupedSummaries(from: decoded)
        cachedGroupedSummaries = grouped
        cachedActiveVehicleCount = grouped.reduce(0) { $0 + $1.locations.reduce(0) { $0 + $1.count } }
        if let defaultDate = defaultExpandedDate(from: grouped) {
            expandedDates = [defaultDate]
        } else {
            expandedDates = []
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                if cachedGroupedSummaries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(cachedGroupedSummaries) { card in
                                dateCard(card)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                    .refreshable {
                        hpdRefreshTrigger += 1
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
                        Text("Dashboard (\(cachedActiveVehicleCount))")
                            .font(.headline.bold())
                            .foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showQuotaSheet = true
                    } label: {
                        if let currentTier = toolbarTierKey {
                            if UIImage(named: currentTier) != nil {
                                Image(currentTier)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 30, height: 30)
                            } else {
                                Image(systemName: "star.shield.fill")
                                    .font(.title2)
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 30, height: 30)
                        }
                    }
                }
            }
            .sheet(isPresented: $showQuotaSheet) {
                QuotaUsageView()
                    .environmentObject(supabaseService)
                    .environmentObject(storeManager)
                    .presentationDetents([.height(300), .medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .task {
            recomputeSummaries()
            if supabaseService.currentTier == nil {
                await supabaseService.fetchCurrentProfile()
            }
        }
        .onChange(of: hpdCachedEntriesData) { _, _ in
            recomputeSummaries()
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
                        NavigationLink(destination: FilteredAuctionListView(
                            date: card.date,
                            location: locEntry.location,
                            brand: nil
                        )) {
                            let headerAuctionDate = locEntry.vehicles.compactMap { parseAuctionDate($0.dateScheduled, timeStr: $0.time) }.first
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundColor(.blue)
                                    .font(.subheadline)
                                    .padding(.top, 2)
                                Text(locEntry.location)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                if let headerAuctionDate = headerAuctionDate {
                                    Text("•")
                                        .foregroundColor(.primary)
                                    Text(headerAuctionDate.compactAuctionTime())
                                        .font(.subheadline.bold())
                                        .foregroundColor(.primary)
                                }
                                Spacer()
                                Text("\(locEntry.count) vehicle\(locEntry.count == 1 ? "" : "s")")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                        }
                        .buttonStyle(.plain)

                        VStack(spacing: 6) {
                            ForEach(locEntry.makes, id: \.make) { makeEntry in
                                NavigationLink(destination: FilteredAuctionListView(
                                    date: card.date,
                                    location: locEntry.location,
                                    brand: makeEntry.make
                                )) {
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
                                        Text(brandDisplayName(for: makeEntry.make))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        HStack(spacing: 4) {
                                            Text("\(makeEntry.count)")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                            Image(systemName: "chevron.right")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .padding(.leading, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
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
