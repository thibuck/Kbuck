import SwiftUI

// MARK: - Data models

private struct InlineSearchBar: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LocationEntry: Identifiable {
    let id       = UUID()
    let location: String
    let vehicles: [HPDEntry]
    let count:    Int
    let headerTime: String?
    let makes:    [(make: String, count: Int)]   // sorted by count desc
}

private struct DateCard: Identifiable {
    let id        = UUID()
    let date:     String
    let dateObj:  Date
    let locations: [LocationEntry]               // sorted by count desc
}

private struct BrandFilterOption: Identifiable {
    let id: String
    let make: String
    let count: Int
}

// MARK: - View

struct HomeSummaryView: View {

    @Binding var selectedTab: Int
    @Binding var targetLocationFilter: String?

    @AppStorage("hpdCachedEntries") private var hpdCachedEntriesData: Data = Data()
    @AppStorage("hpdRefreshTrigger") private var hpdRefreshTrigger: Int = 0
    @AppStorage("vehicleCacheWarmupInProgress") private var vehicleCacheWarmupInProgress: Bool = false
    @State private var cachedGroupedSummaries: [DateCard] = []
    @State private var cachedActiveVehicleCount: Int = 0
    @State private var cachedBrandOptions: [BrandFilterOption] = []
    @State private var hasBaseAuctionData: Bool = false

    // MARK: - Collapse state

    @State private var expandedDates: Set<String> = []
    @State private var isBrandFilterExpanded: Bool = false
    @State private var selectedBrandFilters: Set<String> = []
    @State private var isBrandSearchVisible: Bool = false
    @State private var brandSearchText: String = ""
    @State private var brandFilterAutoCollapseToken = UUID()

    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager
    @AppStorage("userRole") private var userRole: String = "user"
    @State private var showQuotaSheet: Bool = false
    @State private var showBrandLimitAlert: Bool = false

    private var activeHomeSearchText: String {
        brandSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentTierKey: String {
        supabaseService.serverTierKey
    }

    private var toolbarTierKey: String? {
        guard let rawTier = supabaseService.currentTier else { return nil }
        let normalized = rawTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized != "loading" else { return nil }
        return normalized
    }

    private var currentTierDisplayName: String {
        supabaseService.serverTierDisplayName
    }

    private var hasBrandFilterAccess: Bool {
        supabaseService.hasServerPlatinumAccess
    }

    private var currentTierLimit: Int {
        supabaseService.currentServerDailyLimit
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
                        let vehicles = vehicleMap[dateStr]?[skey] ?? []
                        let total = makeHistogram.values.reduce(0, +)
                        let makes = makeHistogram
                            .sorted { $0.value > $1.value }
                            .map { (make: $0.key, count: $0.value) }
                        let headerTime = vehicles.first.flatMap { vehicle in
                            parseAuctionDate(vehicle.dateScheduled, timeStr: vehicle.time)?.compactAuctionTime()
                        }
                        return LocationEntry(
                            location: label,
                            vehicles: vehicles,
                            count: total,
                            headerTime: headerTime,
                            makes: makes
                        )
                    }
                    .sorted { $0.count > $1.count }

                return DateCard(date: dateStr, dateObj: dateObj, locations: locations)
            }
            .sorted { $0.dateObj < $1.dateObj }
    }

    private static func buildBrandOptions(from entries: [HPDEntry]) -> [BrandFilterOption] {
        var makeCounts: [String: Int] = [:]

        for entry in entries {
            guard !isDateInPast(entry.dateScheduled) else { continue }

            let cleanAddress = normalizeAddress(entry.lotAddress)
            guard !cleanAddress.isEmpty else { continue }

            let makeKey = entry.make
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !makeKey.isEmpty else { continue }

            makeCounts[makeKey, default: 0] += 1
        }

        return makeCounts
            .map { BrandFilterOption(id: $0.key, make: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return brandDisplayName(for: $0.make) < brandDisplayName(for: $1.make)
                }
                return $0.count > $1.count
            }
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
            cachedBrandOptions = []
            hasBaseAuctionData = false
            expandedDates = []
            return
        }

        hasBaseAuctionData = !decoded.isEmpty

        let searchQuery = brandSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchFilteredEntries: [HPDEntry]
        if searchQuery.isEmpty {
            searchFilteredEntries = decoded
        } else {
            searchFilteredEntries = decoded.filter { entry in
                vehicleMatchesSearch(searchQuery, entry: entry)
            }
        }

        let brandOptions = Self.buildBrandOptions(from: searchFilteredEntries)
        cachedBrandOptions = brandOptions

        let availableMakes = Set(brandOptions.map(\.make))
        let validSelectedMakes = selectedBrandFilters.intersection(availableMakes)
        if validSelectedMakes != selectedBrandFilters {
            selectedBrandFilters = validSelectedMakes
        }

        if !hasBrandFilterAccess, !selectedBrandFilters.isEmpty {
            selectedBrandFilters = []
        }

        let filteredEntries: [HPDEntry]
        if hasBrandFilterAccess, !selectedBrandFilters.isEmpty {
            filteredEntries = searchFilteredEntries.filter {
                let makeKey = $0.make.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                return selectedBrandFilters.contains(makeKey)
            }
        } else {
            filteredEntries = searchFilteredEntries
        }

        let grouped = Self.buildGroupedSummaries(from: filteredEntries)
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
                if cachedGroupedSummaries.isEmpty && !hasBaseAuctionData {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if hasBrandFilterAccess {
                                brandFilterCard
                            }
                            if cachedGroupedSummaries.isEmpty {
                                noResultsState
                            } else {
                                ForEach(cachedGroupedSummaries) { card in
                                    dateCard(card)
                                }
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
                        if vehicleCacheWarmupInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Image(systemName: "building.columns.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.subheadline)
                        Text("HPD Auction (\(cachedActiveVehicleCount))")
                            .font(.headline)
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
        .alert("Brand Limit Reached", isPresented: $showBrandLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can select up to 5 brands at a time.")
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
        .onChange(of: selectedBrandFilters) { _, _ in
            if isBrandFilterExpanded {
                scheduleBrandFilterAutoCollapse()
            }
            recomputeSummaries()
        }
        .onChange(of: brandSearchText) { _, _ in
            if !brandSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isBrandFilterExpanded = true
            }
            if isBrandFilterExpanded {
                scheduleBrandFilterAutoCollapse()
            }
            if brandSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isBrandSearchVisible = false
            }
            recomputeSummaries()
        }
        .onChange(of: currentTierKey) { _, _ in
            if !hasBrandFilterAccess {
                selectedBrandFilters = []
            }
            recomputeSummaries()
        }
        .onChange(of: userRole) { _, _ in
            if !hasBrandFilterAccess {
                selectedBrandFilters = []
            }
            recomputeSummaries()
        }
    }

    // MARK: - Platinum brand filter

    private var brandFilterCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isBrandFilterExpanded.toggle()
                if isBrandFilterExpanded {
                    scheduleBrandFilterAutoCollapse()
                } else {
                    brandFilterAutoCollapseToken = UUID()
                    if brandSearchText.isEmpty {
                        isBrandSearchVisible = false
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.subheadline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brand Filter")
                        .font(.headline)
                            .foregroundStyle(.primary)
                        if !selectedBrandFilters.isEmpty {
                            Text("\(selectedBrandFilters.count) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !selectedBrandFilters.isEmpty {
                        Text("\(selectedBrandFilters.count)/5")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    Image(systemName: isBrandFilterExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isBrandFilterExpanded {
                Divider()
                    .padding(.top, 12)

                InlineSearchBar(
                    text: $brandSearchText,
                    placeholder: "Year, make, model or VIN"
                )
                .padding(.top, 14)

                if cachedBrandOptions.isEmpty, !brandSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No matching brands for that search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 10)], spacing: 10) {
                    ForEach(cachedBrandOptions) { option in
                        brandFilterChip(for: option)
                    }
                }
                .padding(.top, 14)

                if !selectedBrandFilters.isEmpty {
                    Button("Clear All Brands") {
                        selectedBrandFilters.removeAll()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.top, 14)
                }
            }
        }
        .padding(20)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.primary.opacity(0.08), radius: 10, x: 0, y: 5)
    }

    private func scheduleBrandFilterAutoCollapse() {
        let token = UUID()
        brandFilterAutoCollapseToken = token

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard brandFilterAutoCollapseToken == token, isBrandFilterExpanded else { return }
            guard brandSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            isBrandFilterExpanded = false
        }
    }

    private func brandFilterChip(for option: BrandFilterOption) -> some View {
        let isSelected = selectedBrandFilters.contains(option.make)

        return Button {
            toggleBrandFilter(option.make)
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let asset = brandAssetName(for: option.make),
                       let image = UIImage(named: asset) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "car.fill")
                            .font(.title3)
                            .frame(width: 28, height: 28)
                    }
                }
                .foregroundStyle(isSelected ? .white : .secondary)

                Text(brandDisplayName(for: option.make))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("\(option.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, minHeight: 84)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color(uiColor: .secondarySystemGroupedBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.blue : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggleBrandFilter(_ make: String) {
        if selectedBrandFilters.contains(make) {
            selectedBrandFilters.remove(make)
            return
        }

        guard selectedBrandFilters.count < 5 else {
            showBrandLimitAlert = true
            return
        }

        selectedBrandFilters.insert(make)
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
                        .font(.subheadline)
                    Text(card.date)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(totalForDate) total")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
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
                            brand: nil,
                            allowedBrands: selectedBrandFilters.isEmpty ? nil : Array(selectedBrandFilters).sorted(),
                            initialSearchText: activeHomeSearchText
                        )) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(
                                            locEntry.headerTime.map {
                                                "\(locEntry.location) - \($0)"
                                            } ?? locEntry.location
                                        )
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                        Spacer(minLength: 0)
                                        Text("\(locEntry.count) total")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize()
                                    }

                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        VStack(spacing: 6) {
                            ForEach(locEntry.makes, id: \.make) { makeEntry in
                                NavigationLink(destination: FilteredAuctionListView(
                                    date: card.date,
                                    location: locEntry.location,
                                    brand: makeEntry.make,
                                    allowedBrands: nil,
                                    initialSearchText: activeHomeSearchText
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
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        HStack(spacing: 4) {
                                            Text("\(makeEntry.count)")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Image(systemName: "chevron.right")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .padding(.leading, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(16)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    }
                    .padding(.top, 12)

                    if locEntry.id != card.locations.last?.id {
                        Color.clear
                            .frame(height: 6)
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
                .font(.headline)
            Text("Fetch auction data from the HPD tab to populate the dashboard.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No Results")
                .font(.headline)
            Text("No vehicles match \"\(activeHomeSearchText)\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Clear Search") {
                brandSearchText = ""
                isBrandFilterExpanded = true
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
