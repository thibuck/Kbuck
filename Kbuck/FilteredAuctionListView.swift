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

    @AppStorage("hpdCachedEntries") private var hpdCachedEntriesData: Data = Data()
    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager:   StoreManager

    @State private var searchText = ""

    // MARK: - Base filter (date + location + brand)

    private var filteredEntries: [HPDEntry] {
        guard !hpdCachedEntriesData.isEmpty,
              let all = try? JSONDecoder().decode([HPDEntry].self, from: hpdCachedEntriesData)
        else { return [] }

        let locationKey = streetKey(location)
        let brandUpper  = brand?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        return all.filter { entry in
            let sameDate     = entry.dateScheduled.trimmingCharacters(in: .whitespacesAndNewlines) == date
            let sameLocation = streetKey(entry.lotAddress) == locationKey
            let sameBrand    = brandUpper == nil
                || entry.make.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == brandUpper!
            return sameDate && sameLocation && sameBrand
        }
    }

    // MARK: - Displayed vehicles (base + search + sort)

    private var displayedVehicles: [HPDEntry] {
        // 1. Base Filter
        var filtered = filteredEntries

        // 2. Search Filter (checking the human-readable brand name)
        if !searchText.isEmpty {
            let searchLower = searchText.lowercased()
            filtered = filtered.filter { entry in
                let mappedBrand = brandDisplayName(for: entry.make).lowercased()
                return entry.vin.lowercased().contains(searchLower) ||
                    entry.year.lowercased().contains(searchLower) ||
                    mappedBrand.contains(searchLower) ||
                    entry.model.lowercased().contains(searchLower)
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
        brand.map { brandDisplayName(for: $0) } ?? location
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
                        let brandLabel = brand.map { brandDisplayName(for: $0) } ?? "Any"
                        Text("No \(brandLabel) vehicles found at this location for \(date).")
                    } else {
                        Text("No vehicles match \"\(searchText)\".")
                    }
                }
            } else {
                List {
                    ForEach(displayedVehicles) { entry in
                        VehicleCardView(entry: entry, showAddress: false, showQuickInventory: false, initiallyExpanded: true)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Search VIN, Year, Brand or Model")
        .navigationTitle("\(baseTitle) (\(displayedVehicles.count))")
        .navigationBarTitleDisplayMode(.inline)
    }
}
