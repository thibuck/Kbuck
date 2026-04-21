import SwiftUI

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (r, g, b) = ((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
        default:
            (r, g, b) = (0x1a, 0x6e, 0xf5)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}

private struct LocationsInlineSearchBar: View {
    @Binding var text: String
    let placeholder: String
    @Environment(\.colorScheme) private var colorScheme

    private var searchBarBackground: Color {
        colorScheme == .light ? Color.white.opacity(0.72) : Color(.systemGray6)
    }

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
        .background(searchBarBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LocationFilterOption: Identifiable {
    let id: String
    let location: String
    let count: Int
    let headerTime: String?
}

private struct DateLocationCard: Identifiable {
    let id = UUID()
    let date: String
    let dateObj: Date
    let locations: [LocationFilterOption]
}

struct LocationsSummaryView: View {

    @AppStorage("hpdCachedEntries") private var hpdCachedEntriesData: Data = Data()
    @AppStorage("hpdRefreshTrigger") private var hpdRefreshTrigger: Int = 0
    @AppStorage("vehicleCacheWarmupInProgress") private var vehicleCacheWarmupInProgress: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager

    @State private var cachedGroupedSummaries: [DateLocationCard] = []
    @State private var cachedLocationOptions: [LocationFilterOption] = []
    @State private var cachedActiveVehicleCount: Int = 0
    @State private var hasBaseAuctionData: Bool = false
    @State private var expandedDates: Set<String> = []
    @State private var selectedLocationFilters: Set<String> = []
    @State private var isLocationFilterExpanded: Bool = false
    @State private var locationSearchText: String = ""
    @State private var locationFilterAutoCollapseToken = UUID()
    @State private var showQuotaSheet = false

    private var activeSearchText: String {
        locationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var locationFilterSummaryLabel: String {
        if selectedLocationFilters.count == 1, let only = selectedLocationFilters.first {
            return only
        }
        return "All locations"
    }

    private var locationCardBackground: Color {
        colorScheme == .light ? Color.white.opacity(0.72) : Color(hex: "#C5A455").opacity(0.05)
    }

    private var locationChipBackground: Color {
        colorScheme == .light ? Color.white.opacity(0.72) : Color(.secondarySystemBackground)
    }

    private var locationChipSelectedBackground: Color {
        colorScheme == .light ? Color.white.opacity(0.86) : Color(.tertiarySystemBackground)
    }

    private func displayDateTitle(for rawDate: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = formatter.date(from: rawDate) else { return rawDate }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMMM d, yyyy"
        displayFormatter.locale = Locale(identifier: "en_US_POSIX")
        return displayFormatter.string(from: date)
    }

    private static func normalizeAddress(_ raw: String) -> String {
        var t = raw
            .replacingOccurrences(of: "*", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard t.count >= 5 else { return "" }

        let lower = t.lowercased()
        let hasDigit = t.range(of: "\\d", options: .regularExpression) != nil
        let hasZip = t.range(of: #"\b\d{5}(?:-\d{4})?\b"#, options: .regularExpression) != nil
        let hasStreet = lower.range(of: #"\b(st|ave|rd|dr|blvd|ln|lane|way|pkwy|parkway|court|ct|cir|circle|trl|trail|hwy|highway|suite|ste)\b"#, options: .regularExpression) != nil
        let looksBiz = lower.contains(" llc") || lower.contains(" inc") ||
            lower.contains(" towing") || lower.contains(" storage") ||
            lower.contains(" motors") || lower.contains(" auto ")
        if looksBiz && !(hasStreet || hasZip || hasDigit) { return "" }
        if !(hasStreet || hasZip || hasDigit) { return "" }

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

    private static func buildGroupedSummaries(from entries: [HPDEntry]) -> [DateLocationCard] {
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MM/dd/yyyy"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        var dateMap: [String: [String: [HPDEntry]]] = [:]

        for entry in entries {
            guard !isDateInPast(entry.dateScheduled) else { continue }
            let date = entry.dateScheduled.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = normalizeAddress(entry.lotAddress)
            guard !date.isEmpty, !clean.isEmpty else { continue }
            dateMap[date, default: [:]][clean, default: []].append(entry)
        }

        return dateMap.compactMap { dateStr, locationMap -> DateLocationCard? in
            guard let dateObj = fmt.date(from: dateStr) else { return nil }

            let locations = locationMap.map { label, vehicles in
                LocationFilterOption(
                    id: label,
                    location: label,
                    count: vehicles.count,
                    headerTime: vehicles.first.flatMap { parseAuctionDate($0.dateScheduled, timeStr: $0.time)?.compactAuctionTime() }
                )
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.location < $1.location
                }
                return $0.count > $1.count
            }

            return DateLocationCard(date: dateStr, dateObj: dateObj, locations: locations)
        }
        .sorted { $0.dateObj < $1.dateObj }
    }

    private static func buildLocationOptions(from entries: [HPDEntry]) -> [LocationFilterOption] {
        var locationMap: [String: [HPDEntry]] = [:]

        for entry in entries {
            guard !isDateInPast(entry.dateScheduled) else { continue }
            let clean = normalizeAddress(entry.lotAddress)
            guard !clean.isEmpty else { continue }
            locationMap[clean, default: []].append(entry)
        }

        return locationMap.map { label, vehicles in
            LocationFilterOption(
                id: label,
                location: label,
                count: vehicles.count,
                headerTime: vehicles.first.flatMap { parseAuctionDate($0.dateScheduled, timeStr: $0.time)?.compactAuctionTime() }
            )
        }
        .sorted {
            if $0.count == $1.count {
                return $0.location < $1.location
            }
            return $0.count > $1.count
        }
    }

    private func defaultExpandedDate(from grouped: [DateLocationCard]) -> String? {
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
            cachedLocationOptions = []
            cachedActiveVehicleCount = 0
            hasBaseAuctionData = false
            expandedDates = []
            return
        }

        hasBaseAuctionData = !decoded.isEmpty

        let searchFilteredEntries: [HPDEntry]
        if activeSearchText.isEmpty {
            searchFilteredEntries = decoded
        } else {
            searchFilteredEntries = decoded.filter { entry in
                vehicleMatchesSearch(activeSearchText, entry: entry)
                    || Self.normalizeAddress(entry.lotAddress).localizedCaseInsensitiveContains(activeSearchText)
            }
        }

        let locationOptions = Self.buildLocationOptions(from: searchFilteredEntries)
        cachedLocationOptions = locationOptions

        let validLocations = Set(locationOptions.map(\.location))
        let validSelectedLocations = selectedLocationFilters.intersection(validLocations)
        if validSelectedLocations != selectedLocationFilters {
            selectedLocationFilters = validSelectedLocations
        }

        let filteredEntries: [HPDEntry]
        if !selectedLocationFilters.isEmpty {
            filteredEntries = searchFilteredEntries.filter { entry in
                selectedLocationFilters.contains(Self.normalizeAddress(entry.lotAddress))
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

    var body: some View {
        NavigationStack {
            ZStack {
                AppChromeBackground()
                if cachedGroupedSummaries.isEmpty && !hasBaseAuctionData {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            LocationsInlineSearchBar(
                                text: $locationSearchText,
                                placeholder: "Year, make, model, VIN or location"
                            )

                            locationFilterCard

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
                    HStack(alignment: .top) {
                        if vehicleCacheWarmupInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("HPD AUCTION")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.primary.opacity(0.32))
                                .kerning(2)

                            Text("Locations")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(.primary)
                                .kerning(-1)

                            Rectangle()
                                .fill(Color(hex: "#C5A455"))
                                .frame(width: 24, height: 1.5)
                                .cornerRadius(1)
                        }

                        Spacer()

                        VStack(alignment: .center, spacing: 6) {
                            Text("PLATINUM")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(hex: "#C5A455"))
                                .kerning(1.2)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color(hex: "#C5A455").opacity(0.08))
                                .overlay {
                                    Capsule()
                                        .strokeBorder(Color(hex: "#C5A455").opacity(0.30), lineWidth: 0.5)
                                }
                                .clipShape(Capsule())

                            Text("\(cachedActiveVehicleCount) listings")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(Color.primary.opacity(0.40))
                        }
                        .onTapGesture {
                            showQuotaSheet = true
                        }
                    }
                    .frame(width: UIScreen.main.bounds.width - 40)
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
        .onChange(of: locationSearchText) { _, _ in
            if !activeSearchText.isEmpty {
                isLocationFilterExpanded = true
            }
            if isLocationFilterExpanded {
                scheduleLocationFilterAutoCollapse()
            }
            recomputeSummaries()
        }
        .onChange(of: selectedLocationFilters) { _, _ in
            if isLocationFilterExpanded {
                scheduleLocationFilterAutoCollapse()
            }
            recomputeSummaries()
        }
    }

    private var locationFilterCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .overlay(Color.primary.opacity(0.10))
            Button {
                isLocationFilterExpanded.toggle()
                if isLocationFilterExpanded {
                    scheduleLocationFilterAutoCollapse()
                } else {
                    locationFilterAutoCollapseToken = UUID()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color.primary.opacity(0.40))
                    Text("LOCATION")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.primary.opacity(0.30))
                        .kerning(1)
                    Text("—")
                        .foregroundColor(Color.primary.opacity(0.18))
                    Text(locationFilterSummaryLabel)
                        .font(.system(size: 13))
                        .foregroundColor(Color.primary.opacity(0.74))
                        .lineLimit(1)
                    Spacer()
                    if !selectedLocationFilters.isEmpty {
                        Text("\(selectedLocationFilters.count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.10))
                            .foregroundStyle(Color.primary.opacity(0.48))
                            .clipShape(Capsule())
                    }
                    Image(systemName: isLocationFilterExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(Color.primary.opacity(0.32))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            Divider()
                .overlay(Color.primary.opacity(0.10))

            if isLocationFilterExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(cachedLocationOptions) { option in
                        locationFilterChip(for: option)
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 22)

                if !selectedLocationFilters.isEmpty {
                    Button("Clear All Locations") {
                        selectedLocationFilters.removeAll()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.74))
                    .padding(.top, 14)
                    .padding(.horizontal, 22)
                }
            }
        }
        .background(Color.clear)
    }

    private func locationFilterChip(for option: LocationFilterOption) -> some View {
        let isSelected = selectedLocationFilters.contains(option.location)

        return Button {
            if isSelected {
                selectedLocationFilters.remove(option.location)
            } else {
                selectedLocationFilters = [option.location]
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(isSelected ? 0.82 : 0.46))

                    Spacer()

                    Text("\(option.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.primary.opacity(isSelected ? 0.62 : 0.36))
                }

                Text(option.location)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(Color.primary.opacity(isSelected ? 0.82 : 0.72))

                if let headerTime = option.headerTime, !headerTime.isEmpty {
                    Text(headerTime)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.primary.opacity(isSelected ? 0.56 : 0.38))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? locationChipSelectedBackground : locationChipBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.10), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func scheduleLocationFilterAutoCollapse() {
        let token = UUID()
        locationFilterAutoCollapseToken = token

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard locationFilterAutoCollapseToken == token, isLocationFilterExpanded else { return }
            guard activeSearchText.isEmpty else { return }
            isLocationFilterExpanded = false
        }
    }

    @ViewBuilder
    private func dateCard(_ card: DateLocationCard) -> some View {
        let isExpanded = expandedDates.contains(card.date)
        let totalForDate = card.locations.reduce(0) { $0 + $1.count }
        let displayDate = displayDateTitle(for: card.date)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded {
                    expandedDates.remove(card.date)
                } else {
                    expandedDates.insert(card.date)
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(displayDate)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(Color.primary.opacity(0.84))

                            Spacer()

                            Text("\(totalForDate) vehicles")
                                .font(.system(size: 12))
                                .foregroundColor(Color.primary.opacity(0.38))
                                .monospacedDigit()
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(Color.primary.opacity(0.32))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(card.locations.enumerated()), id: \.element.id) { index, locationEntry in
                        NavigationLink(destination: FilteredAuctionListView(
                            date: card.date,
                            location: locationEntry.location,
                            brand: nil,
                            allowedBrands: nil,
                            initialSearchText: activeSearchText
                        )) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.05))
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        Image(systemName: "mappin.and.ellipse")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color.primary.opacity(0.42))
                                    }
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                                    }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(locationEntry.location)
                                        .font(.system(size: 14.5, weight: .regular))
                                        .foregroundColor(Color.primary.opacity(0.82))
                                        .lineLimit(1)

                                    if let headerTime = locationEntry.headerTime, !headerTime.isEmpty {
                                        Text(headerTime)
                                            .font(.system(size: 12))
                                            .foregroundColor(Color.primary.opacity(0.40))
                                    }
                                }

                                Spacer()

                                HStack(spacing: 4) {
                                    Text("\(locationEntry.count)")
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundColor(Color.primary.opacity(0.40))
                                        .monospacedDigit()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundStyle(Color.primary.opacity(0.24))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                        }
                        .buttonStyle(.plain)

                        if index < card.locations.count - 1 {
                            Divider()
                                .padding(.leading, 52)
                                .overlay(Color.primary.opacity(0.08))
                        }
                    }
                }
                .background(locationCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "map.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.primary.opacity(0.28))
            Text("No Data Available")
                .font(.headline)
                .foregroundStyle(Color.primary.opacity(0.80))
            Text("Fetch auction data to populate the locations view.")
                .font(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.52))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(Color.primary.opacity(0.28))
            Text("No Results")
                .font(.headline)
                .foregroundStyle(Color.primary.opacity(0.80))
            Text("No locations match \"\(activeSearchText)\".")
                .font(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.52))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Clear Search") {
                locationSearchText = ""
                isLocationFilterExpanded = true
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary.opacity(0.74))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
