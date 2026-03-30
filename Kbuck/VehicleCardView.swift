import SwiftUI
import UIKit
import EventKit
import MapKit
import CoreLocation
import StoreKit

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

    let entry: HPDEntry
    var showAddress: Bool = true

    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager
    @AppStorage("userRole")         private var userRole: String = "user"
    @AppStorage("openWebInSafari") private var openWebInSafari: Bool = false

    // MARK: Card state
    @State private var isExpanded: Bool
    
    init(entry: HPDEntry, showAddress: Bool = true, initiallyExpanded: Bool = false) {
        self.entry = entry
        self.showAddress = showAddress
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
    @State private var showWebConfirm = false
    @State private var statVinURL: URL? = nil

    // Quick Data Info
    @State private var showQuickDataInfo = false

    // Carfax
    @State private var showCarfaxTeaser       = false
    @State private var showCarfaxUpsellDialog = false

    // Paywall
    @State private var showPaywall = false

    // Quick Inventory
    @State private var showQuickInventory = false

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
    private var yearStr: String   { normalizedYear(entry.year) }
    private var processed: Bool   { lastProcessedVIN == cardKey }

    private var shareText: String {
        var parts = ["\(yearStr) \(brandDisplayName(for: entry.make)) \(entry.model)", "VIN: \(entry.vin)"]
        if let odo = odoInfo {
            parts.append("Miles: \(odo.odometer.formatWithCommas())")
            let price = odo.privateValue.formatAsCurrency()
            if price != "N/A" { parts.append("Value: \(price)") }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Header (always visible) — tap to expand/collapse ──────────
            HStack(alignment: .center, spacing: 10) {
                if let asset = brandAssetName(for: entry.make) {
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(yearStr) \(brandDisplayName(for: entry.make)) \(entry.model)".uppercased())
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if showAddress {
                        let rawAddress = entry.lotAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rawName    = entry.lotName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let isValidAddress = rawAddress.count > 5
                            && !rawAddress.lowercased().elementsEqual("llc")
                            && !rawAddress.lowercased().elementsEqual("inc")
                        let displayAddr: String = {
                            if isValidAddress {
                                let mapped = sanitizedAddr(rawAddress)
                                return mapped.isEmpty ? rawAddress : mapped
                            } else {
                                return rawName.count > 3 ? rawName : "Location Unavailable"
                            }
                        }()
                        Text(displayAddr)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let info = odoInfo {
                    let odoK = formatOdoK(info.odometer)
                    if odoK != "no odo" {
                        HStack(spacing: 4) {
                            Image(systemName: "fuelpump.fill")
                                .foregroundStyle(.secondary)
                                .font(.headline)
                            Text(odoK)
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    haptic(.light)
                    if isFav {
                        supabaseService.removeFavoriteLocally(cardKey)
                        supabaseService.syncRemoveFavorite(cardKey)
                    } else {
                        pendingFavoriteKey   = cardKey
                        pendingFavoriteEntry = entry
                        pendingFavoriteLabel = "\(yearStr) \(entry.make) \(entry.model) - \(entry.vin)"
                        showFavoriteConfirm  = true
                    }
                } label: {
                    Image(systemName: "star.fill")
                        .font(.title2)
                        .foregroundStyle(isFav ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                haptic(.light)
                withAnimation(.snappy) { isExpanded.toggle() }
            }

            // ── Expanded content ───────────────────────────────────────────
            if isExpanded {
                Divider()

                // VIN row — tap to copy
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("VIN: \(entry.vin)")
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if copiedVIN == entry.vin {
                        Text("Copied!")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 0)
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
                    Button {
                        if storeManager.activeSubscriptionTier == .platinum || userRole == "super_admin" {
                            Task {
                                if let p = storeManager.consumables.first(where: { $0.id == "com.kbuck.carfax.platinum" }) {
                                    _ = try? await storeManager.purchase(p)
                                }
                            }
                        } else {
                            showCarfaxUpsellDialog = true
                        }
                    } label: {
                        Image("carfax")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }

                // Odometer / inspection date / private value
                if let odo = odoInfo {
                    HStack(spacing: 6) {
                        Image(systemName: "fuelpump.fill").foregroundStyle(.secondary)
                        Text(odo.odometer.formatWithCommas() + " miles")
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("\(odo.testDate.dateOnly) \(odo.testDate.dateOnly.timeAgoShort())")
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "banknote.fill")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(odo.privateValue.formatAsCurrency())
                    }
                }

                // Action buttons
                HStack(spacing: 8) {
                    // Hammer — extraction trigger
                    Button {
                        let failStatus = VINFailureTracker.shared.status(for: cardKey)
                        if !failStatus.canTry {
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                            extractionErrorMessage = failStatus.errorMessage
                            showExtractionErrorAlert = true
                            return
                        }
                        Task {
                            let limitStatus = await supabaseService.checkExtractionLimits(vin: cardKey)
                            await MainActor.run {
                                if limitStatus.allowed {
                                    haptic(.medium)
                                    pendingExtractionEntry = entry
                                    showLegalDisclaimer = true
                                } else {
                                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                                    let configs       = supabaseService.tierConfigs
                                    let currentTier   = storeManager.activeSubscriptionTier
                                    let currentLimit  = storeManager.dailyLimit(from: configs)
                                    let limitStr      = currentLimit == Int.max ? "Unlimited" : "\(currentLimit)"
                                    let (nextName, nextLimit): (String, String)
                                    switch currentTier {
                                    case .none:
                                        nextName  = "Silver"
                                        nextLimit = "\(configs["silver"]?.daily_fetch_limit ?? 10)"
                                    case .silver:
                                        nextName  = "Gold"
                                        nextLimit = "\(configs["gold"]?.daily_fetch_limit ?? 30)"
                                    case .gold, .platinum:
                                        nextName  = "Platinum"
                                        nextLimit = "Unlimited"
                                    }
                                    isQuotaExceededAlert     = true
                                    extractionErrorMessage   = "You've reached your daily limit of \(limitStr). Upgrade to \(nextName) to get \(nextLimit) extractions per day!"
                                    showExtractionErrorAlert = true
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "hammer.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VINFailureTracker.shared.status(for: cardKey).isRed ? .red : .blue)
                    .frame(maxWidth: .infinity)

                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up.fill")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button {
                        haptic(.light)
                        pendingCalendarEntry = entry
                        pendingCalendarLabel = "\(yearStr) \(entry.make) \(entry.model) — \(entry.dateScheduled)"
                        showCalendarConfirm  = true
                    } label: {
                        Image(systemName: "calendar.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button {
                        haptic(.light)
                        showWebConfirm = true
                    } label: {
                        Image(systemName: "globe")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button {
                        showQuickDataInfo = true
                    } label: {
                        Image(systemName: "info.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .font(.system(.subheadline))
        .foregroundStyle(.primary)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(processed ? Color.blue.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)

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
        } message: { Text(pendingFavoriteLabel) }

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
                Button("Upgrade Now") {
                    extractionErrorMessage = nil
                    isQuotaExceededAlert   = false
                    showPaywall            = true
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

        .confirmationDialog("Open stat.vin", isPresented: $showWebConfirm, titleVisibility: .visible) {
            Button("Open Report") {
                if let url = URL(string: "https://stat.vin/cars/\(entry.vin)") {
                    if openWebInSafari {
                        UIApplication.shared.open(url)
                    } else {
                        statVinURL = url
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Do you want to view the report for this VIN?") }

        .sheet(isPresented: Binding(get: { statVinURL != nil }, set: { if !$0 { statVinURL = nil } })) {
            if let url = statVinURL { SafariView(url: url).ignoresSafeArea() }
        }

        .alert("Data Information", isPresented: $showQuickDataInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            let isUnlimited = userRole == "super_admin" || storeManager.activeSubscriptionTier == .platinum
            let limit = storeManager.dailyLimit(from: supabaseService.tierConfigs)
            let limitStr = isUnlimited ? "unlimited" : "\(limit)"
            Text("• Mileage: Last recorded odometer during state inspection.\n• Value: Estimated DMV Private Party Value.\n\nUSAGE LIMITS:\nTo ensure system stability, you are limited to \(limitStr) successful data extractions per day, and a maximum of 5 successful extractions per specific vehicle. Failed attempts do not count against your limit.\n\nNOTE: This is historical data from third-party public records. We do not guarantee its accuracy.")
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
            Button("Buy 1 Report for \(stdPrice)") {
                Task { if let p = stdProduct { _ = try? await storeManager.purchase(p) } }
            }
            Button("Upgrade to Platinum (Reports for \(platPrice))") { showPaywall = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Get an instant vehicle history report.") }

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

    private func formatOdoK(_ raw: String) -> String {
        let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
        if digits.isEmpty { return "no odo" }
        guard let val = Int(digits), val > 0 else { return "no odo" }
        return "\(Int(round(Double(val) / 1000.0)))k"
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

    enum ExState: Equatable { case fetchingOdometer, waitingForCaptcha, fetchingPrice }

    @State private var exState:           ExState = .fetchingOdometer
    @State private var cancelToken:       UUID    = UUID()
    @State private var forceStartToken:   UUID    = UUID()
    @State private var mileageVIN:        String
    @State private var spvVIN:            String? = nil
    @State private var spvOdo:            String? = nil
    @State private var errorMessage:      String? = nil
    @State private var showErrorAlert:    Bool    = false

    init(entry: HPDEntry, lastProcessedVIN: Binding<String?>) {
        self.entry            = entry
        self._lastProcessedVIN = lastProcessedVIN
        self._mileageVIN      = State(initialValue: normalizeVIN(entry.vin))
    }

    var body: some View {
        ZStack {
            // Dim backdrop
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            if exState == .waitingForCaptcha {
                VStack {
                    Text("Please check the CAPTCHA box and press the blue Submit button below!")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(uiColor: .systemBackground).opacity(0.9))
                        )
                        .padding(.top, 18)
                    Spacer()
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.15)
                    Text(overlayMessage)
                        .font(.headline)
                    Text(mileageVIN)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .systemBackground).opacity(0.85))
                )
                .padding(20)
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
                    onExtract:            { odo, date in handleOdo(odo: odo, date: date) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: exState == .waitingForCaptcha ? 500 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
                .padding(.horizontal, 14)
                .allowsHitTesting(exState == .waitingForCaptcha)
                .opacity(exState == .waitingForCaptcha ? 1 : 0)
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
        .animation(.snappy, value: exState)
        .onAppear { startWatchdog(for: .fetchingOdometer, token: cancelToken) }
        .alert("Extraction Failed", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { dismiss() }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - Private

    private var overlayMessage: String {
        switch exState {
        case .fetchingOdometer:  return "Fetching odometer data..."
        case .waitingForCaptcha: return "Please solve the CAPTCHA..."
        case .fetchingPrice:     return "Fetching private value..."
        }
    }

    private func handleOdo(odo: String, date: String) {
        DispatchQueue.main.async {
            guard !mileageVIN.isEmpty else { return }
            var info = supabaseService.odoByVIN[mileageVIN] ?? OdoInfo(odometer: "", testDate: "", privateValue: nil)
            info.odometer = odo
            info.testDate = date.dateOnly
            supabaseService.setOdoInfo(info, forVIN: mileageVIN)
            spvVIN  = mileageVIN
            spvOdo  = odo
            exState = .fetchingPrice
            startWatchdog(for: .fetchingPrice, token: cancelToken)
        }
    }

    private func handlePrice(_ price: String) {
        DispatchQueue.main.async {
            if let v = spvVIN, var info = supabaseService.odoByVIN[v] {
                info.privateValue = price
                supabaseService.setOdoInfo(info, forVIN: v)
                Task { await supabaseService.incrementQuota() }
                VINFailureTracker.shared.clearFailures(vin: v)
                lastProcessedVIN = v
            }
            dismiss()
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            if !mileageVIN.isEmpty { VINFailureTracker.shared.recordFailure(vin: mileageVIN) }
            errorMessage   = message
            showErrorAlert = true
        }
    }

    /// Mirrors HPDView.startWatchdogTimer(for:token:) — 8-second auto-fail per phase.
    private func startWatchdog(for state: ExState, token: UUID) {
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                guard self.cancelToken == token, self.exState == state else { return }
                if !self.mileageVIN.isEmpty {
                    VINFailureTracker.shared.recordFailure(vin: self.mileageVIN)
                }
                switch state {
                case .fetchingOdometer:
                    self.errorMessage = "Odometer Fetch Failed: No recent mileage information was found from the last inspection, or the state server is currently unavailable."
                case .fetchingPrice:
                    self.errorMessage = "Value Fetch Failed: The DMV valuation server timed out. The vehicle might not have a calculable private party value at this time."
                case .waitingForCaptcha:
                    self.errorMessage = "Extraction timed out after 8 seconds. Please check your connection and try again."
                }
                self.showErrorAlert = true
            }
        }
    }
}
