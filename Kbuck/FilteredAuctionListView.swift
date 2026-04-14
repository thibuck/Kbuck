import SwiftUI
import UIKit

// MARK: - Swipe-back gesture re-enabler (needed when navigationBarBackButtonHidden is true)
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        DispatchQueue.main.async {
            vc.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            vc.navigationController?.interactivePopGestureRecognizer?.delegate = nil
        }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            uiViewController.navigationController?.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager:   StoreManager

    @State private var searchText: String
    @State private var showDataInfo = false

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

    private var navigationBrandName: String {
        baseTitle
    }

    private func paletteColor(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if isDecoding {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(
                                    value: Double(decodedCount),
                                    total: Double(max(totalToDecode, 1))
                                )
                                .tint(paletteColor("#C5A455"))

                                Text("Decoding VINs: \(decodedCount)/\(totalToDecode)")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.primary.opacity(0.65))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                        }

                        ForEach(displayedVehicles) { entry in
                            VehicleCardView(
                                entry: entry,
                                showAddress: false,
                                showQuickInventory: false,
                                showBrandLogo: false,
                                shouldLoadVINCacheOnAppear: false,
                                layout: .brandList,
                                initiallyExpanded: true
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .searchable(text: $searchText, prompt: "Search VIN, Year, Brand or Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 34, height: 34)
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.primary.opacity(0.55))
                    }
                }
                .buttonStyle(.plain)
            }

            ToolbarItem(placement: .principal) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(navigationBrandName.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.primary.opacity(0.35))
                        .kerning(1.5)
                    Text("\(displayedVehicles.count) vehicles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.primary.opacity(0.82))
                        .kerning(-0.3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDataInfo = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 34, height: 34)
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.primary.opacity(0.55))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationBarBackButtonHidden(true)
        .background(SwipeBackEnabler().frame(width: 0, height: 0))
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .alert("Data Information", isPresented: $showDataInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            let limit = supabaseService.currentServerDailyLimit
            let limitStr = limit == Int.max ? "unlimited" : "\(limit)"
            Text("• Mileage: Last recorded odometer during state inspection.\n• Value: Estimated DMV Private Party Value.\n\nUSAGE LIMITS:\nYou are limited to \(limitStr) successful data extractions per day, and a maximum of 3 per vehicle. Failed attempts do not count.\n\nNOTE: Historical data from third-party public records. Accuracy not guaranteed.")
        }
    }
}
