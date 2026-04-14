import SwiftUI
import UIKit
import EventKit
import MapKit
import CoreLocation
import StoreKit
import Supabase

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - VehicleCardView
//
// Fully self-contained, reusable vehicle card that mirrors 100% of the UI
// and interaction logic from HPDView.card(for:showAddress:).
// Owns all card-level state: expand/collapse, copy-VIN, favorites, calendar,
// Carfax upsell, stat.vin web lookup, quick-data info, and the full
// mileage + private-value extraction flow (via ExtractionFlowView).
//
// Drop this view into any list context — no parent-level orchestration needed.

struct VehicleCardView: View {

    enum LayoutStyle {
        case standard
        case brandList
    }

    let entry: HPDEntry
    var showAddress: Bool = true
    var showQuickInventory: Bool = true
    var showFavoriteButton: Bool = true
    var showBrandLogo: Bool = true
    var isFavoritesContext: Bool = false
    var shouldLoadVINCacheOnAppear: Bool = true
    var layout: LayoutStyle = .standard

    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager
    @AppStorage("userRole")         private var userRole: String = "user"
    @StateObject private var carfaxVault = CarfaxVault.shared

    // MARK: Card state
    @State private var isExpanded: Bool
    
    init(
        entry: HPDEntry,
        showAddress: Bool = true,
        showQuickInventory: Bool = true,
        showFavoriteButton: Bool = true,
        showBrandLogo: Bool = true,
        isFavoritesContext: Bool = false,
        shouldLoadVINCacheOnAppear: Bool = true,
        layout: LayoutStyle = .standard,
        initiallyExpanded: Bool = false
    ) {
        self.entry = entry
        self.showAddress = showAddress
        self.showQuickInventory = showQuickInventory
        self.showFavoriteButton = showFavoriteButton
        self.showBrandLogo = showBrandLogo
        self.isFavoritesContext = isFavoritesContext
        self.shouldLoadVINCacheOnAppear = shouldLoadVINCacheOnAppear
        self.layout = layout
        _isExpanded = State(initialValue: initiallyExpanded)
    }
    @State private var copiedVIN: String? = nil
    @State private var lastProcessedVIN: String? = nil

    // Favorites
    @State private var showFavoriteConfirm  = false
    @State private var pendingFavoriteKey: String? = nil
    @State private var pendingFavoriteEntry: HPDEntry? = nil
    @State private var pendingFavoriteLabel = ""

    // Calendar
    @State private var showCalendarConfirm  = false
    @State private var pendingCalendarEntry: HPDEntry? = nil
    @State private var pendingCalendarLabel = ""

    // Web / stat.vin
    @State private var showStatVinFlow = false
    @State private var statVinURL: URL? = nil
    @State private var carfaxReportURL: URL? = nil

    // Calendar completion
    @State private var isAddedToCalendar = false

    // Quick Data Info
    @State private var showQuickDataInfo = false
    @State private var transientFavoriteDetailTitle: String? = nil
    @State private var transientFavoriteDetail: String? = nil
    @State private var transientFavoriteDetailToken = UUID()

    // Carfax
    @State private var showCarfaxTeaser          = false
    @State private var showCarfaxUpsellDialog    = false
    @State private var showPlatinumCarfaxConfirm = false
    @State private var isFetchingCarfax          = false
    @State private var carfaxErrorMessage: String? = nil
    @State private var showCarfaxErrorAlert      = false

    // Paywall
    @State private var showPaywall = false


    // Extraction
    @State private var showLegalDisclaimer      = false
    @State private var pendingExtractionEntry: HPDEntry? = nil
    @State private var showExtractionFlow       = false
    @State private var extractionErrorMessage: String? = nil
    @State private var showExtractionErrorAlert = false
    @State private var isQuotaExceededAlert     = false

    // MARK: - Derived
    private var cardKey: String   { normalizeVIN(entry.vin) }
    private var isFav:   Bool     { supabaseService.favorites.contains(cardKey) }
    private var odoInfo: OdoInfo? { supabaseService.odoByVIN[entry.vin] ?? supabaseService.odoByVIN[cardKey] }
    private var decodedMake: String? {
        supabaseService.decodedMakeByVIN[entry.vin] ?? supabaseService.decodedMakeByVIN[cardKey]
    }
    private var decodedModel: String? {
        supabaseService.decodedModelByVIN[entry.vin] ?? supabaseService.decodedModelByVIN[cardKey]
    }
    private var engineInfo: String? {
        supabaseService.engineByVIN[entry.vin] ?? supabaseService.engineByVIN[cardKey]
    }
    private var trimInfo: String? {
        let trim = supabaseService.trimByVIN[entry.vin] ?? supabaseService.trimByVIN[cardKey]
        guard let trim, !trim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return trim
    }
    private var cityMpgInfo: String? {
        let mpg = supabaseService.cityMpgByVIN[entry.vin] ?? supabaseService.cityMpgByVIN[cardKey]
        guard let mpg, !mpg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return mpg
    }
    private var hwyMpgInfo: String? {
        let mpg = supabaseService.hwyMpgByVIN[entry.vin] ?? supabaseService.hwyMpgByVIN[cardKey]
        guard let mpg, !mpg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return mpg
    }
    private var displayMake: String { decodedMake ?? brandDisplayName(for: entry.make) }
    private var displayModel: String { decodedModel ?? odoInfo?.realModel?.capitalized ?? entry.model }
    private var cardTitle: String {
        let baseTitle = "\(yearStr) \(displayMake) \(displayModel)"
        guard let trimInfo else { return baseTitle }
        return "\(baseTitle) \(trimInfo)"
    }
    private var homeEngineMpgText: String? {
        guard !isFavoritesContext, let engine = engineInfo else { return nil }

        let normalizedEngine = engine.replacingOccurrences(of: " V", with: " v")
        let mpgSuffix: String
        switch (cityMpgInfo, hwyMpgInfo) {
        case let (city?, hwy?):
            mpgSuffix = " - mpg city: \(city) hwy: \(hwy)"
        case let (city?, nil):
            mpgSuffix = " - mpg city: \(city)"
        case let (nil, hwy?):
            mpgSuffix = " - hwy: \(hwy)"
        default:
            mpgSuffix = ""
        }

        return normalizedEngine + mpgSuffix
    }
    private var favoriteEngineLabel: String? {
        guard isFavoritesContext, let engine = engineInfo else { return nil }
        return engine.replacingOccurrences(of: " V", with: " v")
    }
    private var favoriteMpgDetail: String? {
        guard isFavoritesContext else { return nil }
        switch (cityMpgInfo, hwyMpgInfo) {
        case let (city?, hwy?):
            return "City: \(city)  Hwy: \(hwy)"
        case let (city?, nil):
            return "City: \(city)"
        case let (nil, hwy?):
            return "Hwy: \(hwy)"
        default:
            return nil
        }
    }
    private var yearStr: String   { normalizedYear(entry.year) }
    private var processed: Bool   { lastProcessedVIN == cardKey }
    private var currentServerDailyLimit: Int {
        supabaseService.currentServerDailyLimit
    }
    private var isPlatinumRateEligible: Bool {
        supabaseService.hasServerPlatinumAccess
    }
    private var hasStatVinAccess: Bool {
        supabaseService.hasServerPaidPlan
    }
    private var statVinLookupStatus: StatVinLookupStatus {
        supabaseService.statVinStatus(for: cardKey)
    }
    private var statVinButtonTint: Color {
        switch statVinLookupStatus {
        case .unknown:
            return .gray
        case .noHistory:
            return Color(red: 0.28, green: 0.72, blue: 0.98)
        case .hasHistory:
            return Color(red: 1.0, green: 0.33, blue: 0.68)
        }
    }
    private var statVinStatusLabel: String? {
        switch statVinLookupStatus {
        case .unknown:
            return nil
        case .noHistory:
            return "No pics"
        case .hasHistory:
            return "Pics found"
        }
    }
    private var statVinIcon: String {
        switch statVinLookupStatus {
        case .unknown:    return "globe"
        case .hasHistory: return "photo.fill"
        case .noHistory:  return "photo.fill"
        }
    }
    private var isCarfaxEnabled: Bool {
        supabaseService.isCarfaxEnabled
    }
    private var hasSavedCarfaxReport: Bool {
        carfaxVault.getReportURL(for: entry.vin) != nil
    }
    private var cardSurfaceColor: Color { Color(.systemBackground) }
    private var cardElevatedColor: Color { Color(.tertiarySystemBackground) }
    private var cardBorderColor: Color { Color.primary.opacity(0.10) }
    private var cardPrimaryTextColor: Color { Color.primary.opacity(0.82) }
    private var cardSecondaryTextColor: Color { Color.primary.opacity(0.44) }
    private var neutralActionTint: Color { Color.primary.opacity(0.18) }
    private var primaryActionTint: Color { Color(hex: "#C5A455").opacity(0.52) }

    private var shareText: String {
        var parts = ["\(yearStr) \(displayMake) \(displayModel)", "VIN: \(entry.vin)"]
        let addr = entry.lotAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !addr.isEmpty {
            var locationLine = addr
            if let time = entry.time, !time.isEmpty { locationLine += " • \(time)" }
            parts.append(locationLine)
        }
        if let odo = odoInfo {
            parts.append("Miles: \(odo.odometer.formatWithCommas())")
            let price = odo.privateValue.formatAsCurrency()
            if price != "N/A" { parts.append("Value: \(price)") }
        }
        if let engine = engineInfo { parts.append("Engine: \(engine)") }
        return parts.joined(separator: "\n")
    }

    private var calendarEntryLabel: String {
        "\(yearStr) \(displayMake) \(displayModel) - \(entry.dateScheduled)"
    }

    private var brandListModelTrim: String {
        let combined = [displayModel, trimInfo]
            .compactMap { value -> String? in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    return nil
                }
                return value
            }
            .joined(separator: " ")

        return titleCasedVehicleText(combined)
    }

    private var brandListCityMPG: String? {
        cityMpgInfo?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var brandListHighwayMPG: String? {
        hwyMpgInfo?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var brandListMileage: String? {
        guard let rawOdo = odoInfo?.odometer else { return nil }
        let digits = rawOdo.filter(\.isNumber)
        guard let value = Int(digits), value > 0 else { return nil }
        return String(value).formatWithCommas()
    }

    private var brandListEngine: String? {
        guard let engineInfo else { return nil }
        let trimmed = engineInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.replacingOccurrences(of: " V", with: " v")
    }

    private var brandListMpgSummary: String? {
        switch (brandListCityMPG, brandListHighwayMPG) {
        case let (city?, highway?):
            return "\(city)/\(highway) mpg"
        case let (city?, nil):
            return "\(city) mpg"
        case let (nil, highway?):
            return "\(highway) mpg"
        default:
            return nil
        }
    }

    private func titleCasedVehicleText(_ text: String) -> String {
        text
            .split(separator: " ")
            .map { rawPart in
                let part = String(rawPart)
                if part.rangeOfCharacter(from: .decimalDigits) != nil {
                    return part.uppercased()
                }
                if part.count <= 3 && part == part.uppercased() {
                    return part
                }
                let lower = part.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private func handleFavoriteTap() {
        haptic(.light)
        if isFav {
            supabaseService.removeFavoriteLocally(cardKey)
            supabaseService.syncRemoveFavorite(cardKey)
        } else {
            pendingFavoriteKey = cardKey
            pendingFavoriteEntry = entry
            pendingFavoriteLabel = "\(yearStr) \(entry.make) \(entry.model) - \(entry.vin)"
            showFavoriteConfirm = true
        }
    }

    private func handleBidTap() {
        let failStatus = VINFailureTracker.shared.status(for: cardKey)
        if !failStatus.canTry {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            extractionErrorMessage = failStatus.errorMessage
            showExtractionErrorAlert = true
            return
        }

        let currentLimit = currentServerDailyLimit
        let currentUsage = supabaseService.currentProfile?.effectiveDailyUsage ?? 0
        let isUnlimited = currentLimit == Int.max

        if !isUnlimited && currentUsage >= currentLimit {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let limitStr = "\(currentLimit)"
            isQuotaExceededAlert = true
            if let offer = nextUpgradeOffer() {
                extractionErrorMessage = "You've reached your daily limit of \(limitStr). Upgrade to \(offer.name) to unlock up to \(offer.limit) daily extractions."
            } else {
                extractionErrorMessage = "You've reached your daily limit of \(limitStr) for your current plan."
            }
            showExtractionErrorAlert = true
            return
        }

        haptic(.medium)
        pendingExtractionEntry = entry
        showLegalDisclaimer = true
    }

    private func handleCalendarTap() {
        haptic(.light)
        pendingCalendarEntry = entry
        pendingCalendarLabel = calendarEntryLabel
        showCalendarConfirm = true
    }

    private func handleWebTap() {
        haptic(.light)
        switch statVinLookupStatus {
        case .hasHistory:
            if let url = URL(string: "https://stat.vin/cars/\(entry.vin)") {
                statVinURL = url
            }
        case .unknown, .noHistory:
            showStatVinFlow = true
        }
    }

    private func nextUpgradeOffer() -> (name: String, limit: String)? {
        switch supabaseService.serverTierKey {
        case "free":
            return ("Silver", "\(supabaseService.serverDailyLimit(forTierKey: "silver"))")
        case "silver":
            return ("Gold", "\(supabaseService.serverDailyLimit(forTierKey: "gold"))")
        case "gold":
            return ("Platinum", "Unlimited")
        default:
            return nil
        }
    }

    private var relativeInspectionText: String {
        guard let odo = odoInfo else { return "" }
        return odo.testDate.dateOnly
            .timeAgoShort()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    @ViewBuilder
    private func favoriteMetricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardElevatedColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorderColor.opacity(0.7), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func favoriteInlineValueRow(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(cardSecondaryTextColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(cardSecondaryTextColor)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(cardPrimaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func brandListSecondaryButtonLabel(icon: String, tint: Color = .white.opacity(0.38)) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: "#1A1A1A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
                )

            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
    }

    private var brandListBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(yearStr)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.25))
                        .kerning(1)

                    Text("\(displayMake) \(brandListModelTrim)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                        .kerning(-0.4)
                        .lineLimit(1)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.vin)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.28))
                            .kerning(0.2)
                            .lineLimit(1)

                        if let brandListMpgSummary {
                            Text(brandListMpgSummary)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.22))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showFavoriteButton {
                    Button(action: handleFavoriteTap) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "#1A1A1A"))
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                                )

                            Image(systemName: isFav ? "heart.fill" : "heart")
                                .font(.system(size: 12))
                                .foregroundColor(
                                    isFav
                                        ? Color(hex: "#C5A455").opacity(0.85)
                                        : .white.opacity(0.22)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()
                .opacity(0.05)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MILES")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.20))
                        .kerning(1)

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(brandListMileage ?? "—")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.70))

                        if brandListMileage != nil {
                            Text("mi")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.20))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)

                Divider()
                    .frame(height: 28)
                    .opacity(0.06)

                VStack(alignment: .leading, spacing: 2) {
                    Text("PRICE")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.20))
                        .kerning(1)

                    Text(odoInfo?.privateValue.formatAsCurrency() ?? "—")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(odoInfo != nil ? .white.opacity(0.70) : .white.opacity(0.20))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)

                Divider()
                    .frame(height: 28)
                    .opacity(0.06)

                VStack(alignment: .leading, spacing: 2) {
                    Text("ENGINE")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.20))
                        .kerning(1)

                    Text(brandListEngine ?? "—")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 14)
            }
            .padding(.vertical, 10)

            Divider()
                .opacity(0.05)

            HStack(spacing: 6) {
                if odoInfo == nil && !isFavoritesContext {
                    Button(action: handleBidTap) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(hex: "#C5A455"))
                            Text("Bid")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(hex: "#C5A455"))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color(hex: "#C5A455").opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color(hex: "#C5A455").opacity(0.22), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }

                ShareLink(item: shareText) {
                    brandListSecondaryButtonLabel(icon: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                if !isAddedToCalendar {
                    Button(action: handleCalendarTap) {
                        brandListSecondaryButtonLabel(icon: "calendar.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }

                if hasStatVinAccess {
                    Button(action: handleWebTap) {
                        brandListSecondaryButtonLabel(
                            icon: statVinIcon,
                            tint: statVinLookupStatus == .unknown
                                ? .white.opacity(0.38)
                                : statVinButtonTint.opacity(0.85)
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if showBrandLogo, let asset = brandAssetName(for: displayMake) {
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .padding(6)
                        .background(cardElevatedColor, in: Circle())
                }

                Text(cardTitle.uppercased())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(cardPrimaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                if let rawOdo = odoInfo?.odometer,
                   let odoInt = Int(rawOdo.filter(\.isNumber)),
                   !isFavoritesContext {
                    let odoInK = odoInt / 1000
                    HStack(spacing: 4) {
                        Image(systemName: "fuelpump.fill")
                            .foregroundColor(cardSecondaryTextColor)
                        Text("\(odoInK)k")
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                    .layoutPriority(1)
                }

                if showQuickInventory {
                    Button {
                        showQuickDataInfo = true
                    } label: {
                        Image(systemName: "bolt.car.fill")
                            .font(.subheadline)
                            .foregroundStyle(cardSecondaryTextColor)
                    }
                    .buttonStyle(.plain)
                }

                if showFavoriteButton {
                    Button(action: handleFavoriteTap) {
                        Image(systemName: "star.fill")
                            .font(.subheadline)
                            .foregroundStyle(isFav ? AnyShapeStyle(primaryActionTint) : AnyShapeStyle(cardSecondaryTextColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                haptic(.light)
                isExpanded.toggle()
            }

            if isExpanded {
                Divider()
                    .overlay(Color.primary.opacity(0.07))

                Group {
                    if isFavoritesContext {
                        favoriteInlineValueRow(title: "VIN", value: entry.vin, systemImage: "tag.fill")
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "tag.fill")
                                .font(.subheadline)
                                .foregroundStyle(cardSecondaryTextColor)
                            Text("VIN: \(entry.vin)")
                                .font(.footnote)
                                .foregroundStyle(cardPrimaryTextColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if copiedVIN == entry.vin {
                                Text("Copied!")
                                    .font(.caption2)
                                    .foregroundStyle(primaryActionTint)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    UIPasteboard.general.string = entry.vin
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    copiedVIN = entry.vin
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copiedVIN = nil
                    }
                }
                .overlay(alignment: .trailing) {
                    if hasSavedCarfaxReport || isCarfaxEnabled {
                        Button {
                            if hasSavedCarfaxReport {
                                openReport(for: entry.vin)
                            } else if storeManager.carfaxCredits > 0 {
                                Task { await fetchCarfaxReport() }
                            } else {
                                showCarfaxUpsellDialog = true
                            }
                        } label: {
                            if isFetchingCarfax {
                                ProgressView()
                                    .frame(width: 32, height: 32)
                            } else {
                                Image("carfax")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 32, height: 32)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let odo = odoInfo {
                    if isFavoritesContext {
                        HStack(spacing: 10) {
                            Button {
                                let relative = relativeInspectionText.isEmpty ? "" : " (\(relativeInspectionText))"
                                showTransientFavoriteDetail(title: "Last Inspection", value: "\(odo.testDate.dateOnly)\(relative)")
                            } label: {
                                favoriteMetricCard(
                                    title: "Miles",
                                    value: "\((Int(odo.odometer.filter(\.isNumber)) ?? 0) / 1000)k"
                                )
                            }
                            .buttonStyle(.plain)
                            favoriteMetricCard(
                                title: "Price",
                                value: odo.privateValue.formatAsCurrency()
                            )
                            if let engine = favoriteEngineLabel {
                                Button {
                                    if let favoriteMpgDetail {
                                        showTransientFavoriteDetail(title: "MPG", value: favoriteMpgDetail)
                                    }
                                } label: {
                                    favoriteMetricCard(title: "Engine", value: engine)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if let transientFavoriteDetailTitle, let transientFavoriteDetail {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transientFavoriteDetailTitle.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(cardSecondaryTextColor)
                                Text(transientFavoriteDetail)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(cardPrimaryTextColor)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(cardElevatedColor)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(cardBorderColor.opacity(0.7), lineWidth: 0.5)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "fuelpump.fill")
                                .font(.footnote)
                                .foregroundStyle(cardSecondaryTextColor)
                            Text(odo.odometer.formatWithCommas() + " miles")
                                .font(.footnote)
                                .foregroundStyle(cardPrimaryTextColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !isFavoritesContext {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.fill")
                                .font(.footnote)
                                .foregroundStyle(cardSecondaryTextColor)
                            Text("\(odo.testDate.dateOnly) \(odo.testDate.dateOnly.timeAgoShort())")
                                .font(.footnote)
                                .foregroundStyle(cardPrimaryTextColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !isFavoritesContext {
                        HStack(spacing: 6) {
                            Image(systemName: "banknote.fill")
                                .font(.footnote)
                                .foregroundStyle(cardSecondaryTextColor)
                            Text(odo.privateValue.formatAsCurrency())
                                .font(isFavoritesContext ? .subheadline.weight(.semibold) : .footnote)
                                .foregroundStyle(cardPrimaryTextColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let engineText = homeEngineMpgText {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(cardSecondaryTextColor)
                        Text(engineText)
                            .font(.footnote)
                            .foregroundStyle(cardPrimaryTextColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 8) {
                    if odoInfo == nil {
                        Button(action: handleBidTap) {
                            Image(systemName: "hammer.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(VINFailureTracker.shared.status(for: cardKey).isRed ? .red.opacity(0.75) : primaryActionTint)
                        .frame(maxWidth: .infinity)
                    }

                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(neutralActionTint)
                    .frame(maxWidth: .infinity)

                    if !isAddedToCalendar {
                        Button(action: handleCalendarTap) {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .tint(neutralActionTint)
                        .frame(maxWidth: .infinity)
                    }

                    if hasStatVinAccess {
                        VStack(spacing: 4) {
                            Button(action: handleWebTap) {
                                Image(systemName: statVinIcon)
                            }
                            .buttonStyle(.bordered)
                            .tint(statVinButtonTint)
                            .frame(maxWidth: .infinity)

                            if let statVinStatusLabel {
                                Text(statVinStatusLabel)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(statVinButtonTint.opacity(0.92))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Button {
                        showQuickDataInfo = true
                    } label: {
                        Image(systemName: "info.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(neutralActionTint)
                    .frame(maxWidth: .infinity)

                    if hasSavedCarfaxReport {
                        Button {
                            openReport(for: entry.vin)
                        } label: {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(cardPrimaryTextColor)
                        }
                        .buttonStyle(.bordered)
                        .tint(neutralActionTint)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if layout == .brandList {
                brandListBody
            } else {
                standardBody
            }
        }
        .font(.system(.subheadline))
        .foregroundStyle(layout == .brandList ? AnyShapeStyle(.white.opacity(0.82)) : AnyShapeStyle(cardPrimaryTextColor))
        .padding(layout == .brandList ? 0 : 16)
        .background(layout == .brandList ? Color(hex: "#111111") : cardSurfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: layout == .brandList ? 14 : 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: layout == .brandList ? 14 : 16, style: .continuous)
                .stroke(
                    layout == .brandList
                        ? Color.white.opacity(0.08)
                        : (processed ? primaryActionTint.opacity(0.6) : cardBorderColor),
                    lineWidth: 0.5
                )
        )
        .shadow(
            color: .black.opacity(layout == .brandList || isFavoritesContext ? 0 : 0.24),
            radius: layout == .brandList || isFavoritesContext ? 0 : 12,
            x: 0,
            y: 6
        )
        .task(id: cardKey) {
            guard shouldLoadVINCacheOnAppear else { return }
            await supabaseService.loadNHTSACacheForVIN(cardKey)
        }

        // MARK: - Modifiers: Alerts & Sheets

        .alert("Add to Favorites", isPresented: $showFavoriteConfirm) {
            Button("Cancel", role: .cancel) { pendingFavoriteKey = nil }
            Button("Add") {
                if let key = pendingFavoriteKey {
                    supabaseService.addFavoriteLocally(key)
                    if let e = pendingFavoriteEntry {
                        supabaseService.syncUpsertFavorite(entry: e)
                    } else {
                        supabaseService.syncAddFavorite(key)
                    }
                    pendingFavoriteKey   = nil
                    pendingFavoriteEntry = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        } message: {
            Text("\(pendingFavoriteLabel)\n\nThis vehicle will be moved to Favorites.")
        }

        .alert("Agregar al calendario", isPresented: $showCalendarConfirm) {
            Button("Cancelar", role: .cancel) { pendingCalendarEntry = nil }
            Button("Agregar") {
                if let e = pendingCalendarEntry {
                    addToCalendar(entry: e)
                    pendingCalendarEntry = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        } message: { Text(pendingCalendarLabel) }

        .alert(isQuotaExceededAlert ? "Daily Limit Reached" : "Extraction Failed",
               isPresented: $showExtractionErrorAlert) {
            Button("Cancel", role: .cancel) {
                extractionErrorMessage = nil
                isQuotaExceededAlert   = false
            }
            if isQuotaExceededAlert {
                if nextUpgradeOffer() != nil {
                    Button("Upgrade Now") {
                        extractionErrorMessage = nil
                        isQuotaExceededAlert   = false
                        showPaywall            = true
                    }
                }
            }
        } message: { Text(extractionErrorMessage ?? "An unknown error occurred.") }

        .alert("Legal Disclaimer", isPresented: $showLegalDisclaimer) {
            Button("Cancel", role: .cancel) { pendingExtractionEntry = nil }
            Button("Accept & Fetch") {
                if let e = pendingExtractionEntry {
                    let sanitizedVIN = normalizeVIN(e.vin)
                    supabaseService.syncLogLegalAgreement(vin: sanitizedVIN)
                    UIPasteboard.general.string = sanitizedVIN
                    showExtractionFlow      = true
                    pendingExtractionEntry  = nil
                }
            }
        } message: {
            if let e = pendingExtractionEntry {
                Text("You are about to fetch the last recorded inspection date, reported mileage, and an estimated DMV Private Value for the \(normalizedYear(e.year)) \(e.make) \(e.model).\n\nDISCLAIMER:\nThis data is retrieved from public third-party sources and is provided 'AS IS' strictly for informational purposes.\n\nNO WARRANTIES:\nWe make no warranties regarding its accuracy, completeness, or current validity.\n\nLIABILITY:\nBy proceeding, you agree that we accept no liability for any decisions made based on this data.")
            }
        }

        .fullScreenCover(isPresented: $showStatVinFlow) {
            StatVinFlowView(
                vin: entry.vin,
                cardKey: cardKey,
                initialFlowState: statVinLookupStatus == .noHistory ? .noPhotos : .confirming,
                onSaveResult: { resolvedURL in
                    let status = Self.statVinStatus(for: resolvedURL)
                    guard status != .unknown else { return }
                    Task {
                        await supabaseService.saveStatVinLookupResult(
                            forVIN: cardKey,
                            status: status,
                            resolvedURL: resolvedURL
                        )
                    }
                }
            )
        }

        .sheet(isPresented: Binding(get: { statVinURL != nil }, set: { if !$0 { statVinURL = nil } })) {
            if let url = statVinURL {
                StatVinBrowserView(initialURL: url) { resolvedURL in
                    let status = Self.statVinStatus(for: resolvedURL)
                    guard status != .unknown else { return }
                    Task {
                        await supabaseService.saveStatVinLookupResult(
                            forVIN: cardKey,
                            status: status,
                            resolvedURL: resolvedURL
                        )
                    }
                }
                .ignoresSafeArea()
            }
        }

        .sheet(isPresented: Binding(get: { carfaxReportURL != nil }, set: { if !$0 { carfaxReportURL = nil } })) {
            if let url = carfaxReportURL {
                NavigationStack {
                    SafariControllerView(url: url)
                        .ignoresSafeArea()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    UIApplication.shared.open(url)
                                } label: {
                                    Image(systemName: "safari")
                                }
                            }
                        }
                }
            }
        }

        .alert("Data Information", isPresented: $showQuickDataInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            let isUnlimited = currentServerDailyLimit == Int.max
            let limit = currentServerDailyLimit
            let limitStr = isUnlimited ? "unlimited" : "\(limit)"
            Text("• Mileage: Last recorded odometer during state inspection.\n• Value: Estimated DMV Private Party Value.\n\nUSAGE LIMITS:\nTo ensure system stability, you are limited to \(limitStr) successful data extractions per day, and a maximum of 3 successful extractions per specific vehicle. Failed attempts do not count against your limit.\n\nNOTE: This is historical data from third-party public records. We do not guarantee its accuracy.")
        }

        .alert("Carfax Report", isPresented: $showCarfaxTeaser) {
            Button("Cancel", role: .cancel) {}
            Button("View Plans") { showPaywall = true }
        } message: {
            Text("Carfax reports are available exclusively for Platinum Plans. Upgrade your account to unlock this feature.")
        }

        .alert("Carfax Report", isPresented: $showCarfaxUpsellDialog) {
            let stdProduct  = storeManager.consumables.first(where: { $0.id == "com.kbuck.carfax.standard" })
            let platProduct = storeManager.consumables.first(where: { $0.id == "com.kbuck.carfax.platinum" })
            let stdPrice    = stdProduct?.displayPrice  ?? "$15.99"
            let platPrice   = platProduct?.displayPrice ?? "$10.99"
            if isPlatinumRateEligible {
                Button("Buy 1 Report for \(platPrice)") {
                    Task { await purchaseAndFetchCarfax(preferredProductID: "com.kbuck.carfax.platinum") }
                }
            } else {
                Button("Buy 1 Report for \(stdPrice)") {
                    Task { await purchaseAndFetchCarfax(preferredProductID: "com.kbuck.carfax.standard") }
                }
                Button("Upgrade to Platinum (Reports for \(platPrice))") { showPaywall = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isPlatinumRateEligible
                 ? "Get an instant vehicle history report at your discounted Platinum rate."
                 : "Get an instant vehicle history report.")
        }

        .alert("Carfax Report", isPresented: $showPlatinumCarfaxConfirm) {
            let platProduct = storeManager.consumables.first(where: { $0.id == "com.kbuck.carfax.platinum" })
            let platPrice = platProduct?.displayPrice ?? "$10.99"
            Button("Buy 1 Report for \(platPrice)") {
                Task { await purchaseAndFetchCarfax(preferredProductID: "com.kbuck.carfax.platinum") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Get an instant vehicle history report at your discounted Platinum rate.")
        }

        .alert("Carfax Error", isPresented: $showCarfaxErrorAlert) {
            Button("OK", role: .cancel) {
                carfaxErrorMessage = nil
            }
        } message: {
            Text(carfaxErrorMessage ?? "Unable to load the Carfax report.")
        }

        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .onChange(of: storeManager.purchasedSubscriptions) { _, _ in
                    Task { await supabaseService.fetchCurrentProfile() }
                }
        }

        .fullScreenCover(isPresented: $showExtractionFlow) {
            ExtractionFlowView(entry: entry, lastProcessedVIN: $lastProcessedVIN)
                .environmentObject(supabaseService)
                .environmentObject(storeManager)
        }
    }

    // MARK: - Private helpers (mirrors HPDView private helpers)

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func showTransientFavoriteDetail(title: String, value: String) {
        if transientFavoriteDetail == value {
            transientFavoriteDetailToken = UUID()
            transientFavoriteDetailTitle = nil
            transientFavoriteDetail = nil
            return
        }

        let token = UUID()
        transientFavoriteDetailToken = token
        transientFavoriteDetailTitle = title
        transientFavoriteDetail = value

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard transientFavoriteDetailToken == token else { return }
            transientFavoriteDetailTitle = nil
            transientFavoriteDetail = nil
        }
    }

    private func formatOdoK(_ raw: String) -> String {
        let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
        if digits.isEmpty { return "no odo" }
        guard let val = Int(digits), val > 0 else { return "no odo" }
        return "\(Int(round(Double(val) / 1000.0)))k"
    }

    private func openReport(for vin: String) {
        guard let url = carfaxVault.getReportURL(for: vin) else { return }
        carfaxReportURL = url
    }

    private nonisolated static func statVinStatus(for url: URL) -> StatVinLookupStatus {
        let lowercasedURL = url.absoluteString.lowercased()
        if lowercasedURL.contains("stat.vin/vin-decoding/") {
            return .noHistory
        }
        if lowercasedURL.contains("stat.vin/cars/") {
            return .hasHistory
        }
        return .unknown
    }

    private func fetchCarfaxReport() async {
        guard isCarfaxEnabled else { return }
        let vin = normalizeVIN(entry.vin)
        guard !vin.isEmpty else { return }
        guard !isFetchingCarfax else { return }

        isFetchingCarfax = true
        defer { isFetchingCarfax = false }

        do {
            let result = try await CarfaxReportFetcher.fetchReport(
                requestPayload: CarfaxFetchRequest(
                    vin: vin,
                    year: normalizedYear(entry.year),
                    make: brandDisplayName(for: entry.make),
                    model: preferredCarfaxModel(),
                    rawMake: entry.make,
                    rawModel: entry.model
                ),
                accessToken: supabase.auth.currentSession?.accessToken ?? ""
            )
            carfaxVault.saveReport(
                vin: vin,
                html: result.html,
                year: entry.year,
                make: entry.make,
                model: entry.model,
                cheapvhrReportID: result.cheapvhrReportID
            )
            if let url = carfaxVault.getReportURL(for: vin) {
                carfaxReportURL = url
            }
        } catch {
            presentCarfaxError(error.localizedDescription)
        }
    }

    private func purchaseAndFetchCarfax(preferredProductID productID: String) async {
        var product = storeManager.consumables.first(where: { $0.id == productID })
        if product == nil {
            await storeManager.requestProducts()
            product = storeManager.consumables.first(where: { $0.id == productID })
        }

        guard let product else {
            presentCarfaxError("Unable to load the Carfax purchase option from the App Store.")
            return
        }

        do {
            if try await storeManager.purchase(product) {
                await fetchCarfaxReport()
            }
        } catch {
            let message = error.localizedDescription
            if !message.isEmpty {
                presentCarfaxError(message)
            }
        }
    }

    private func presentCarfaxError(_ details: String) {
        carfaxErrorMessage = details
        showCarfaxErrorAlert = true
    }

    private func preferredCarfaxModel() -> String {
        if let realModel = odoInfo?.realModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !realModel.isEmpty {
            return realModel
        }

        return decodedModel ?? normalizedModelName(for: entry.model, make: entry.make)
    }

    /// Mirrors HPDView.sanitizedAddressForMaps(_:) exactly.
    private func sanitizedAddr(_ lotAddress: String) -> String {
        let t = lotAddress
            .replacingOccurrences(of: "*",        with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\n",       with: " ")
            .replacingOccurrences(of: "\\s+",     with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        let lower = t.lowercased()
        let hasDigit       = t.range(of: "\\d", options: .regularExpression) != nil
        let hasZip         = t.range(of: #"\b\d{5}(?:-\d{4})?\b"#, options: .regularExpression) != nil
        let hasStreet      = lower.range(of: #"\b(st|ave|rd|dr|blvd|ln|lane|way|pkwy|parkway|court|ct|cir|circle|trl|trail|hwy|highway|suite|ste)\b"#,
                                         options: .regularExpression) != nil
        let looksBusiness  = lower.contains(" inc") || lower.contains(" inc.") ||
                             lower.contains(" llc") || lower.contains(" llc.") ||
                             lower.contains(" co ")  || lower.contains(" company") ||
                             lower.contains(" towing") || lower.contains(" storage") ||
                             lower.contains(" motors") || lower.contains(" auto ")
        if looksBusiness && !(hasStreet || hasZip || hasDigit) { return "" }
        if !(hasStreet || hasZip || hasDigit)                  { return "" }
        return t
    }

    /// Mirrors HPDView.parseAuctionDate(_:timeStr:).
    private func parseAuctionDateWithTime(_ dateStr: String, timeStr: String?) -> Date? {
        let base = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = (timeStr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let df = DateFormatter()
        df.locale   = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        if !time.isEmpty {
            for f in ["MM/dd/yyyy h:mm:ss a","MM/dd/yyyy h:mm a","M/d/yyyy h:mm:ss a","M/d/yyyy h:mm a",
                      "MM/dd/yy h:mm:ss a","MM/dd/yy h:mm a","M/d/yy h:mm:ss a","M/d/yy h:mm a"] {
                df.dateFormat = f
                if let d = df.date(from: "\(base) \(time)") { return d }
            }
        }
        for f in ["MM/dd/yyyy","M/d/yyyy","MM/dd/yy","M/d/yy"] {
            df.dateFormat = f
            if let d = df.date(from: base) { return d }
        }
        return nil
    }

    /// Mirrors HPDView.addToCalendar(entry:) exactly.
    private func addToCalendar(entry e: HPDEntry) {
        let cachedInfo  = supabaseService.odoByVIN[normalizeVIN(e.vin)]
        let store       = EKEventStore()

        let requestHandler: (Bool, Error?) -> Void = { granted, err in
            guard err == nil, granted else { return }
            let event   = EKEvent(eventStore: store)
            event.title = "Auction: \(normalizedYear(e.year)) \(e.make) \(e.model)"

            let addrForCal = sanitizedAddr(e.lotAddress)
            event.location = e.lotAddress
            if !addrForCal.isEmpty {
                let q = addrForCal.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? addrForCal
                event.url = URL(string: "http://maps.apple.com/?q=\(q)")
            }

            let start       = parseAuctionDateWithTime(e.dateScheduled, timeStr: e.time) ?? Date()
            event.startDate = start
            event.endDate   = start.addingTimeInterval(3600)
            event.calendar  = store.defaultCalendarForNewEvents

            var notes: [String] = []
            if !addrForCal.isEmpty {
                notes.append("Address: \(addrForCal)")
                if let mapURL = event.url { notes.append("Maps: \(mapURL.absoluteString)") }
            }
            notes.append("Lot: \(e.lotName)")
            notes.append("VIN: \(e.vin)")
            if !e.plate.isEmpty             { notes.append("Plate: \(e.plate)") }
            if let t = e.time, !t.isEmpty   { notes.append("Time: \(t)") }
            if let info = cachedInfo {
                if !info.odometer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notes.append("Odometer: \(info.odometer)")
                }
                if let pv = info.privateValue,
                   !pv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notes.append("Private Value: \(pv)")
                }
            }
            event.notes = notes.joined(separator: "\n")
            event.addAlarm(EKAlarm(relativeOffset: -30 * 60))

            func finalizeSave() {
                do {
                    try store.save(event, span: .thisEvent)
                    DispatchQueue.main.async {
                        isAddedToCalendar = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        let ti = Int(event.startDate.timeIntervalSinceReferenceDate)
                        if let url = URL(string: "calshow:\(ti)") {
                            UIApplication.shared.open(url)
                        }
                    }
                } catch {}
            }

            if !addrForCal.isEmpty {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = addrForCal
                MKLocalSearch(request: request).start { response, _ in
                    if let item = response?.mapItems.first {
                        let location: CLLocation
                        if #available(iOS 26.0, *) {
                            location = item.location
                        } else {
                            location = CLLocation(
                                latitude:  item.placemark.coordinate.latitude,
                                longitude: item.placemark.coordinate.longitude
                            )
                        }
                        let structured    = EKStructuredLocation(title: addrForCal)
                        structured.geoLocation = location
                        structured.radius      = 100
                        event.structuredLocation = structured
                    }
                    finalizeSave()
                }
            } else {
                finalizeSave()
            }
        }

        if #available(iOS 17.0, *) {
            store.requestWriteOnlyAccessToEvents(completion: requestHandler)
        } else {
            store.requestAccess(to: .event, completion: requestHandler)
        }
    }
}

// MARK: - ExtractionFlowView
//
// Presented via .fullScreenCover from VehicleCardView when the user accepts
// the legal disclaimer. Owns the complete mileage → private-value state
// machine and the hidden MileageWebView / SPVWebView instances.
// Mirrors the ZStack overlay logic from HPDView.body exactly.

struct ExtractionFlowView: View {

    let entry: HPDEntry
    @Binding var lastProcessedVIN: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var supabaseService: SupabaseService

    enum ExState: Equatable { case fetchingOdometer, waitingForCaptcha, fetchingPrice, success, failed }

    @State private var exState:           ExState = .fetchingOdometer
    @State private var cancelToken:       UUID    = UUID()
    @State private var forceStartToken:   UUID    = UUID()
    @State private var mileageVIN:        String
    @State private var spvVIN:            String? = nil
    @State private var spvOdo:            String? = nil
    @State private var errorMessage:      String? = nil
    @State private var showErrorAlert:    Bool    = false
    @State private var glowPulse:         Bool    = false
    @State private var shimmerX:          CGFloat = -60
    @State private var contentOpacity:    Double  = 0
    @State private var addedToFavorites:  Bool    = false
    @State private var heartScale:        CGFloat = 1.0

    private let gold = Color(hex: "#C5A455")
    private var cardKey: String { normalizeVIN(entry.vin) }
    private var isAlreadyFavorite: Bool { supabaseService.favorites.contains(cardKey) }

    init(entry: HPDEntry, lastProcessedVIN: Binding<String?>) {
        self.entry            = entry
        self._lastProcessedVIN = lastProcessedVIN
        self._mileageVIN      = State(initialValue: normalizeVIN(entry.vin))
    }

    var body: some View {
        ZStack {
            // Dark background
            Color(hex: "#0A0A0A").ignoresSafeArea()

            // Gold grid
            Canvas { ctx, size in
                let spacing: CGFloat = 36
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: .init(x: x, y: 0))
                    path.addLine(to: .init(x: x, y: size.height))
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: .init(x: 0, y: y))
                    path.addLine(to: .init(x: size.width, y: y))
                    y += spacing
                }
                ctx.stroke(path, with: .color(gold.opacity(0.035)), lineWidth: 0.5)
            }
            .ignoresSafeArea()

            // Pulsing radial glow
            RadialGradient(
                colors: [gold.opacity(0.10), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 300
            )
            .scaleEffect(glowPulse ? 1.12 : 0.88)
            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: glowPulse)
            .ignoresSafeArea()

            if exState == .waitingForCaptcha {
                VStack {
                    Text("Please check the CAPTCHA box and press the blue Submit button below!")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.88))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(hex: "#1A1A1A"))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        )
                        .padding(.top, 18)
                        .padding(.horizontal, 14)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    LoneStarView(gold: gold)
                        .frame(width: 38, height: 38)
                        .shadow(color: gold.opacity(0.40), radius: 14)
                        .padding(.bottom, 22)

                    Text("\(entry.year) \(entry.make) \(entry.model)".uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.30))
                        .kerning(1.4)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)

                    Text(overlayMessage)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .kerning(-0.6)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 26)

                    if exState == .success {
                        // Success state
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(gold)
                            .shadow(color: gold.opacity(0.5), radius: 12)
                            .padding(.bottom, 20)

                        // Obtained data cards
                        let resultInfo = supabaseService.odoByVIN[mileageVIN]
                        HStack(spacing: 10) {
                            VStack(spacing: 4) {
                                Text("ODOMETER")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.28))
                                    .kerning(1.2)
                                Text(resultInfo?.odometer.formatWithCommas() ?? "—")
                                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.88))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                Text("miles")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.white.opacity(0.22))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                            )

                            VStack(spacing: 4) {
                                Text("VALUE")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.28))
                                    .kerning(1.2)
                                Text(resultInfo?.privateValue?.formatAsCurrency() ?? "—")
                                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                                    .foregroundColor(gold.opacity(0.90))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                Text("private")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.white.opacity(0.22))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(gold.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(gold.opacity(0.18), lineWidth: 0.5)
                            )
                        }
                        .padding(.bottom, 20)

                        Text(mileageVIN)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.20))
                            .kerning(0.4)
                            .padding(.bottom, 22)

                        if addedToFavorites {
                            // Post-add confirmation
                            VStack(spacing: 14) {
                                HStack(spacing: 8) {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(gold)
                                        .scaleEffect(heartScale)
                                    Text("Added to Favorites!")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(gold)
                                }

                                Button { dismiss() } label: {
                                    Text("OK")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(Color(hex: "#0A0A0A"))
                                        .padding(.horizontal, 48)
                                        .padding(.vertical, 12)
                                        .background(gold)
                                        .clipShape(Capsule())
                                        .shadow(color: gold.opacity(0.35), radius: 8)
                                }
                            }
                        } else if isAlreadyFavorite {
                            Button { dismiss() } label: {
                                Text("OK")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Color(hex: "#0A0A0A"))
                                    .padding(.horizontal, 48)
                                    .padding(.vertical, 12)
                                    .background(gold)
                                    .clipShape(Capsule())
                                    .shadow(color: gold.opacity(0.35), radius: 8)
                            }
                        } else {
                            // Offer to add to favorites
                            VStack(spacing: 10) {
                                Text("Save to favorites?")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.36))

                                HStack(spacing: 12) {
                                    Button {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        supabaseService.addFavoriteLocally(cardKey)
                                        supabaseService.syncUpsertFavorite(entry: entry)
                                        withAnimation(.interpolatingSpring(stiffness: 180, damping: 10)) {
                                            addedToFavorites = true
                                            heartScale = 1.4
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                            withAnimation(.easeOut(duration: 0.3)) {
                                                heartScale = 1.0
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "heart.fill")
                                            Text("Add to Favorites")
                                        }
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(Color(hex: "#0A0A0A"))
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 11)
                                        .background(gold)
                                        .clipShape(Capsule())
                                        .shadow(color: gold.opacity(0.30), radius: 6)
                                    }
                                    .buttonStyle(.plain)

                                    Button { dismiss() } label: {
                                        Text("Skip")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.white.opacity(0.38))
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 11)
                                            .background(Color.white.opacity(0.07))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                    } else if exState == .failed {
                        // Error state
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 38))
                            .foregroundColor(.red.opacity(0.80))
                            .padding(.bottom, 16)

                        Text(mileageVIN)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.22))
                            .kerning(0.4)
                            .padding(.bottom, 30)

                        Button { dismiss() } label: {
                            Text("Close")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                                .padding(.horizontal, 30)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.09))
                                .clipShape(Capsule())
                        }
                    } else {
                        // Loading shimmer bar
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 180, height: 5)

                            Capsule()
                                .fill(LinearGradient(
                                    colors: [gold.opacity(0), gold.opacity(0.90), gold.opacity(0)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: 70, height: 5)
                                .offset(x: shimmerX)
                                .clipped()
                        }
                        .frame(width: 180)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                                .frame(width: 180, height: 5)
                        }
                        .padding(.bottom, 14)

                        // Step dots
                        HStack(spacing: 8) {
                            Circle()
                                .fill(exState == .fetchingOdometer ? gold : gold.opacity(0.28))
                                .frame(width: 5, height: 5)
                            Circle()
                                .fill(exState == .fetchingPrice ? gold : gold.opacity(0.18))
                                .frame(width: 5, height: 5)
                        }
                        .padding(.bottom, 26)

                        Text(mileageVIN)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.22))
                            .kerning(0.4)
                            .padding(.bottom, 36)

                        Button { dismiss() } label: {
                            Text("Cancel")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.35))
                                .padding(.horizontal, 30)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.07))
                                .clipShape(Capsule())
                        }
                    }
                }
                .opacity(contentOpacity)
                .padding(.horizontal, 32)
            }

            // MileageWebView — hidden when fetching, visible at height 500 for captcha
            if let mUrl = URL(string: "https://www.mytxcar.org/TXCar_Net/SecurityCheck.aspx") {
                MileageWebView(
                    url:                  mUrl,
                    isActive:             true,
                    vin:                  mileageVIN,
                    cancelToken:          cancelToken,
                    forceStartToken:      forceStartToken,
                    onWaitingForCaptcha:  { DispatchQueue.main.async { exState = .waitingForCaptcha } },
                    onFetchingOdometer:   { DispatchQueue.main.async { exState = .fetchingOdometer } },
                    onError:              { msg in fail(msg) },
                    onExtract:            { odo, date, realModel in handleOdo(odo: odo, date: date, realModel: realModel) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: exState == .waitingForCaptcha ? 500 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
                .padding(.horizontal, 14)
                .allowsHitTesting(exState == .waitingForCaptcha)
                .opacity(exState == .waitingForCaptcha ? 1 : 0)
                .opacity(exState == .success || exState == .failed ? 0 : 1)
            }

            // SPVWebView — always zero-sized, runs silently in background
            if exState == .fetchingPrice,
               let spvURL = URL(string: "https://tools.txdmv.gov/tools/SPV/spv_lookup.php") {
                SPVWebView(
                    url:         spvURL,
                    isActive:    true,
                    vin:         spvVIN ?? "",
                    mileage:     spvOdo ?? "",
                    cancelToken: cancelToken,
                    onError:     { msg in fail(msg) }
                ) { price in
                    handlePrice(price)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: exState)
        .onAppear {
            glowPulse = true
            withAnimation(.easeOut(duration: 0.5)) { contentOpacity = 1 }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                shimmerX = 180
            }
            Task {
                async let cacheResult = supabaseService.loadQuickDataCacheFromSupabase(forVIN: mileageVIN)
                async let minDelay: Void = Task.sleep(nanoseconds: 1_500_000_000)
                let (hit, _) = await (cacheResult, try? minDelay)
                if hit {
                    await supabaseService.incrementQuota(vin: mileageVIN)
                    await MainActor.run {
                        VINFailureTracker.shared.clearFailures(vin: mileageVIN)
                        lastProcessedVIN = mileageVIN
                        exState = .success
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    return
                }

                await MainActor.run {
                    startWatchdog(for: .fetchingOdometer, token: cancelToken)
                }
            }
        }
    }

    // MARK: - Private

    private var overlayMessage: String {
        switch exState {
        case .fetchingOdometer:  return "Fetching odometer..."
        case .waitingForCaptcha: return "Solve the CAPTCHA"
        case .fetchingPrice:     return "Fetching private value..."
        case .success:           return "Data loaded!"
        case .failed:            return errorMessage ?? "Something went wrong."
        }
    }

    private func handleOdo(odo: String, date: String, realModel: String?) {
        DispatchQueue.main.async {
            guard !mileageVIN.isEmpty else { return }
            guard self.exState == .fetchingOdometer || self.exState == .waitingForCaptcha else {
                print("[ExtractionFlow] handleOdo IGNORED — exState=\(self.exState) odo=\(odo)")
                return
            }
            print("[ExtractionFlow] handleOdo OK — odo=\(odo) date=\(date)")
            var info = supabaseService.odoByVIN[mileageVIN] ?? OdoInfo(odometer: "", testDate: "", privateValue: nil)
            info.odometer = odo
            info.testDate = date.dateOnly
            info.realModel = realModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? realModel?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            supabaseService.setOdoInfo(info, forVIN: mileageVIN)
            spvVIN  = mileageVIN
            spvOdo  = odo
            exState = .fetchingPrice
            startWatchdog(for: .fetchingPrice, token: cancelToken)
        }
    }

    private func handlePrice(_ price: String) {
        DispatchQueue.main.async {
            guard self.exState == .fetchingPrice else {
                print("[ExtractionFlow] handlePrice IGNORED — exState=\(self.exState) price=\(price)")
                return
            }
            print("[ExtractionFlow] handlePrice OK — price=\(price)")
            if let v = spvVIN, var info = supabaseService.odoByVIN[v] {
                info.privateValue = price
                supabaseService.setOdoInfo(info, forVIN: v)
                VINFailureTracker.shared.clearFailures(vin: v)
                Task {
                    await supabaseService.saveQuickDataCacheToSupabase(forVIN: v)
                    await supabaseService.incrementQuota(vin: v)
                }
                lastProcessedVIN = v
            }
            exState = .success
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            guard self.exState != .success && self.exState != .failed else {
                print("[ExtractionFlow] fail IGNORED — exState=\(self.exState) msg=\(message)")
                return
            }
            print("[ExtractionFlow] fail FIRED — exState=\(self.exState) msg=\(message)")
            if !mileageVIN.isEmpty { VINFailureTracker.shared.recordFailure(vin: mileageVIN) }
            errorMessage = message
            exState = .failed
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Mirrors HPDView.startWatchdogTimer(for:token:) — 8-second auto-fail per phase.
    private func startWatchdog(for state: ExState, token: UUID) {
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                guard self.cancelToken == token, self.exState == state else { return }
                switch state {
                case .fetchingOdometer:
                    self.fail("Odometer Fetch Failed: No recent mileage information was found from the last inspection, or the state server is currently unavailable.")
                case .fetchingPrice:
                    self.fail("Value Fetch Failed: The DMV valuation server timed out. The vehicle might not have a calculable private party value at this time.")
                case .waitingForCaptcha:
                    self.fail("Extraction timed out. Please check your connection and try again.")
                case .success, .failed:
                    break
                }
            }
        }
    }
}

// MARK: - StatVinFlowView
//
// Shown instead of an alert when the user taps the globe/photo button.
// - .confirming  → dark/gold intro screen asking if they want to search history
// - .noPhotos    → dark/gold result screen shown when no photos were found
//   (also shown immediately on subsequent taps when status is already .noHistory)
// When the browser resolves to noHistory it dismisses itself and transitions to .noPhotos.
// When status is .hasHistory the card opens the browser directly, bypassing this view.

struct StatVinFlowView: View {

    enum FlowState { case confirming, noPhotos }

    let vin: String
    let cardKey: String
    let onSaveResult: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var flowState: FlowState
    @State private var showBrowser = false
    @State private var glowPulse  = false
    @State private var contentOpacity: Double = 0

    private let gold = Color(hex: "#C5A455")

    init(
        vin: String,
        cardKey: String,
        initialFlowState: FlowState,
        onSaveResult: @escaping (URL) -> Void
    ) {
        self.vin          = vin
        self.cardKey      = cardKey
        self.onSaveResult = onSaveResult
        _flowState        = State(initialValue: initialFlowState)
    }

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0A").ignoresSafeArea()

            Canvas { ctx, size in
                let spacing: CGFloat = 36
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: .init(x: x, y: 0))
                    path.addLine(to: .init(x: x, y: size.height))
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: .init(x: 0, y: y))
                    path.addLine(to: .init(x: size.width, y: y))
                    y += spacing
                }
                ctx.stroke(path, with: .color(gold.opacity(0.035)), lineWidth: 0.5)
            }
            .ignoresSafeArea()

            RadialGradient(
                colors: [gold.opacity(0.10), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 300
            )
            .scaleEffect(glowPulse ? 1.12 : 0.88)
            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: glowPulse)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                LoneStarView(gold: gold)
                    .frame(width: 38, height: 38)
                    .shadow(color: gold.opacity(0.40), radius: 14)
                    .padding(.bottom, 28)

                if flowState == .confirming {
                    Text("AUCTION HISTORY")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.28))
                        .kerning(1.8)
                        .padding(.bottom, 10)

                    Text("Search for Photos")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .kerning(-0.6)
                        .padding(.bottom, 16)

                    Text("We'll check this vehicle's auction history to find any photos reported during previous auctions.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.42))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)

                    HStack(spacing: 12) {
                        Button { showBrowser = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                Text("Search History")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(hex: "#0A0A0A"))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(gold)
                            .clipShape(Capsule())
                            .shadow(color: gold.opacity(0.35), radius: 8)
                        }
                        .buttonStyle(.plain)

                        Button { dismiss() } label: {
                            Text("Not Now")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.38))
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.07))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                } else {
                    // noPhotos state
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 42))
                            .foregroundColor(.white.opacity(0.13))
                        Circle()
                            .fill(Color(hex: "#0A0A0A"))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.red.opacity(0.65))
                            )
                            .offset(x: 8, y: 8)
                    }
                    .padding(.bottom, 24)

                    Text("NO PHOTOS FOUND")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.28))
                        .kerning(1.8)
                        .padding(.bottom, 10)

                    Text("No auction photos were found for this vehicle in its reported history record.")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.42))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 36)

                    Text(vin)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.20))
                        .kerning(0.4)
                        .padding(.bottom, 30)

                    Button { dismiss() } label: {
                        Text("OK")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(hex: "#0A0A0A"))
                            .padding(.horizontal, 48)
                            .padding(.vertical, 12)
                            .background(gold)
                            .clipShape(Capsule())
                            .shadow(color: gold.opacity(0.35), radius: 8)
                    }
                }
            }
            .opacity(contentOpacity)
            .padding(.horizontal, 32)
        }
        .animation(.easeInOut(duration: 0.35), value: flowState)
        .onAppear {
            glowPulse = true
            withAnimation(.easeOut(duration: 0.5)) { contentOpacity = 1 }
        }
        .sheet(isPresented: $showBrowser) {
            if let url = URL(string: "https://stat.vin/cars/\(vin)") {
                StatVinBrowserView(initialURL: url) { resolvedURL in
                    onSaveResult(resolvedURL)
                    if resolvedURL.absoluteString.lowercased().contains("stat.vin/vin-decoding/") {
                        DispatchQueue.main.async {
                            showBrowser = false
                            withAnimation(.easeInOut(duration: 0.35)) { flowState = .noPhotos }
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
    }
}
