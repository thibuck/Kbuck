import SwiftUI

// MARK: - FilteredAuctionListView
//
// Drill-down destination from Dashboard brand/location rows.
// Filters hpdCachedEntries by date + location + optional brand,
// adds a native search bar, sorts by year descending, and shows
// the live vehicle count in the navigation title.

struct FilteredAuctionListView: View {

    let date:     String
    let location: String
    let brand:    String?
    let allowedBrands: [String]?
    let initialSearchText: String

    @AppStorage("hpdCachedEntries") private var hpdCachedEntriesData: Data = Data()
    @AppStorage("nhtsaDecodedCount") private var decodedCount: Int = 0
    @AppStorage("nhtsaTotalToDecode") private var totalToDecode: Int = 0
    @AppStorage("nhtsaIsDecoding") private var isDecoding: Bool = false
    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager:   StoreManager

    @State private var searchText: String

    init(
        date: String,
        location: String,
        brand: String?,
        allowedBrands: [String]? = nil,
        initialSearchText: String = ""
    ) {
        self.date = date
        self.location = location
        self.brand = brand
        self.allowedBrands = allowedBrands
        self.initialSearchText = initialSearchText
        self._searchText = State(initialValue: initialSearchText)
    }

    // MARK: - Base filter (date + location + brand)

    private var filteredEntries: [HPDEntry] {
        guard !hpdCachedEntriesData.isEmpty,
              let all = try? JSONDecoder().decode([HPDEntry].self, from: hpdCachedEntriesData)
        else { return [] }

        let locationKey = streetKey(location)
        let brandUpper  = brand?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let allowedBrandSet = Set((allowedBrands ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        })
        let shouldHideFavorites = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return all.filter { entry in
            let sameDate     = entry.dateScheduled.trimmingCharacters(in: .whitespacesAndNewlines) == date
            let sameLocation = streetKey(entry.lotAddress) == locationKey
            let entryMake = entry.make.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let sameBrand: Bool
            if let brandUpper {
                sameBrand = entryMake == brandUpper
            } else if !allowedBrandSet.isEmpty {
                sameBrand = allowedBrandSet.contains(entryMake)
            } else {
                sameBrand = true
            }
            let isFavorite   = supabaseService.favorites.contains(normalizeVIN(entry.vin))
            return sameDate && sameLocation && sameBrand && (!shouldHideFavorites || !isFavorite)
        }
    }

    // MARK: - Displayed vehicles (base + search + sort)

    private var displayedVehicles: [HPDEntry] {
        // 1. Base Filter
        var filtered = filteredEntries

        // 2. Search Filter (checking the human-readable brand name)
        if !searchText.isEmpty {
            filtered = filtered.filter { entry in
                let odoInfo = supabaseService.odoByVIN[entry.vin] ?? supabaseService.odoByVIN[normalizeVIN(entry.vin)]
                return vehicleMatchesSearch(searchText, entry: entry, odoInfo: odoInfo)
            }
        }

        // 3. Mathematical Sorting (Newest First)
        return filtered.sorted { (Int($0.year) ?? 0) > (Int($1.year) ?? 0) }
    }

    // MARK: - Helpers

    private func streetKey(_ s: String) -> String {
        s.components(separatedBy: CharacterSet.decimalDigits.inverted)
         .first { !$0.isEmpty } ?? s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var baseTitle: String {
        if let brand {
            return brandDisplayName(for: brand)
        }
        if let allowedBrands, allowedBrands.count == 1, let onlyBrand = allowedBrands.first {
            return brandDisplayName(for: onlyBrand)
        }
        return location
    }

    private var emptyStateBrandLabel: String {
        if let brand {
            return brandDisplayName(for: brand)
        }
        if let allowedBrands, !allowedBrands.isEmpty {
            return allowedBrands.count == 1 ? brandDisplayName(for: allowedBrands[0]) : "selected brands"
        }
        return "Any"
    }

    // MARK: - Body

    var body: some View {
        Group {
            if displayedVehicles.isEmpty {
                ContentUnavailableView {
                    Label(
                        searchText.isEmpty ? "No Vehicles Found" : "No Results",
                        systemImage: "magnifyingglass"
                    )
                } description: {
                    if searchText.isEmpty {
                        Text("No \(emptyStateBrandLabel) vehicles found at this location for \(date).")
                    } else {
                        Text("No vehicles match \"\(searchText)\".")
                    }
                }
            } else {
                List {
                    if isDecoding {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(
                                    value: Double(decodedCount),
                                    total: Double(max(totalToDecode, 1))
                                )
                                Text("Decoding VINs: \(decodedCount)/\(totalToDecode)")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    ForEach(displayedVehicles) { entry in
                        VehicleCardView(
                            entry: entry,
                            showAddress: false,
                            showQuickInventory: false,
                            showBrandLogo: false,
                            shouldLoadVINCacheOnAppear: false,
                            initiallyExpanded: true
                        )
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Search VIN, Year, Brand or Model")
        .navigationTitle("\(baseTitle.uppercased()) (\(displayedVehicles.count))")
        .navigationBarTitleDisplayMode(.inline)
    }
}
