//
//  SupabaseService.swift
//  Kbuck
//
//  Centralises all Supabase interaction for the Favorites feature.
//  Holds authoritative @Published state for favorites and odometer cache,
//  persisting them to UserDefaults (same keys as the old @AppStorage slots).
//

import Foundation
import Combine
import WebKit
import Supabase

// MARK: - Supabase Client (module-scoped singleton)
//
// ⚠️  SECURITY: This MUST be the anon/publishable key only.
//     Decoded payload → {"role":"anon"} ✓ — confirmed safe.
//     NEVER paste the service_role key here; it bypasses ALL RLS policies.
//
private let supabaseURLString = "https://tnescuqegmehazuffmte.supabase.co"
private let fallbackSupabaseURL = URL(string: "https://example.com") ?? URL(fileURLWithPath: "/")

let supabase = SupabaseClient(
    supabaseURL: URL(string: supabaseURLString) ?? fallbackSupabaseURL,
    supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRuZXNjdXFlZ21laGF6dWZmbXRlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM2OTI4ODEsImV4cCI6MjA4OTI2ODg4MX0.LszstZi962himWPuoSWEXR9Xzhbl2ncewJSGzTnoeIg",
    options: SupabaseClientOptions(auth: SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true))
)



// MARK: - Remote Tier Config

struct TierConfig: Codable {
    let tier_name: String
    let daily_fetch_limit: Int
    let max_favorites: Int
}

struct AppSettingsRow: Codable {
    let carfax_enabled: Bool?
}

// MARK: - Rate Limit Response

struct RateLimitResponse: Codable {
    let allowed: Bool
    let reason: String?
}

// MARK: - User Usage Profile

struct UserUsageProfile: Codable {
    let scrape_count_today: Int
    let last_scrape_reset: String?
    let plan_tier: String?

    /// Client-side timezone-aware quota count.
    ///
    /// Supabase performs a *lazy* reset: `scrape_count_today` is only zeroed
    /// the next time the user makes an extraction, not at midnight.
    /// If the stored `last_scrape_reset` date (parsed in the America/Chicago /
    /// Texas timezone) falls strictly before today in that same timezone,
    /// the DB value is stale and we return 0 so the UI always shows the truth.
    /// Falls back to the raw `scrape_count_today` if date parsing fails.
    var effectiveDailyUsage: Int {
        guard let raw = last_scrape_reset else { return scrape_count_today }

        // Normalise the Supabase timestamp — it may contain a space instead of 'T'
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        var resetDate: Date?

        // 1. ISO8601 with fractional seconds + timezone
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        resetDate = isoFull.date(from: normalized)

        // 2. ISO8601 without fractional seconds
        if resetDate == nil {
            let isoBasic = ISO8601DateFormatter()
            isoBasic.formatOptions = [.withInternetDateTime]
            resetDate = isoBasic.date(from: normalized)
        }

        // 3. Manual fallback formats (Supabase sometimes omits the 'T')
        if resetDate == nil {
            let df = DateFormatter()
            df.locale   = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            for fmt in [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
                "yyyy-MM-dd HH:mm:ssZZZZZ",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd"
            ] {
                df.dateFormat = fmt
                if let d = df.date(from: raw) { resetDate = d; break }
            }
        }

        guard let resetDate else { return scrape_count_today }

        // Compare calendar *days* in America/Chicago — the server's reset boundary
        guard let centralTimeZone = TimeZone(identifier: "America/Chicago") else {
            return scrape_count_today
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = centralTimeZone
        let todayStart = cal.startOfDay(for: Date())
        let resetStart = cal.startOfDay(for: resetDate)

        // If the reset day predates today (CT) the DB hasn't lazy-reset yet → show 0
        return resetStart < todayStart ? 0 : scrape_count_today
    }

    var effectiveScrapeCount: Int {
        effectiveDailyUsage
    }
}

// MARK: - Favorites Table Row Model

struct FavoriteRow: Codable {
    var user_id: UUID?      // NOT NULL in DB; always set before INSERT/UPSERT
    var vin: String
    var year: String?
    var make: String?
    var model: String?
    var odometer: String?
    var test_date: String?
    var private_value: String?
}

struct QuickDataCacheRow: Codable {
    var vin: String
    var odometer: String?
    var test_date: String?
    var private_value: String?
    var real_model: String?
}

// MARK: - Service

@MainActor final class SupabaseService: ObservableObject {

    // Published state — HPDView observes these directly
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var odoByVIN: [String: OdoInfo] = [:]
    @Published private(set) var decodedMakeByVIN: [String: String] = [:]
    @Published private(set) var decodedModelByVIN: [String: String] = [:]
    @Published private(set) var engineByVIN: [String: String] = [:]
    @Published private(set) var trimByVIN: [String: String] = [:]
    @Published private(set) var bodyClassByVIN: [String: String] = [:]
    @Published private(set) var cityMpgByVIN: [String: String] = [:]
    @Published private(set) var hwyMpgByVIN: [String: String] = [:]
    @Published private(set) var currentProfile: UserUsageProfile? = nil
    @Published private(set) var currentTier: String? = nil
    @Published private(set) var tierConfigs: [String: TierConfig] = [:]
    @Published private(set) var isCarfaxEnabled: Bool = true
    private var nhtsaCacheObserver: NSObjectProtocol?

    // UserDefaults keys (same as the old @AppStorage keys so data migrates automatically)
    private let favKey  = "hpdFavorites"
    private let odoKey  = "hpdOdoCache"
    private let carfaxEnabledKey = "appSettingsCarfaxEnabled"

    /// Synchronous shortcut — currentUser is backed by in-memory session, zero network cost.
    private var currentUserID: UUID? { supabase.auth.currentUser?.id }

    private func normalizedTierKey(_ rawTier: String?) -> String {
        let normalized = rawTier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized! : "free"
    }

    var serverTierKey: String {
        normalizedTierKey(currentProfile?.plan_tier)
    }

    var serverTierDisplayName: String {
        serverTierKey.capitalized
    }

    var isServerSuperAdmin: Bool {
        (UserDefaults.standard.string(forKey: "userRole") ?? "user") == "super_admin"
    }

    var hasServerPaidPlan: Bool {
        isServerSuperAdmin || ["silver", "gold", "platinum"].contains(serverTierKey)
    }

    var hasServerPlatinumAccess: Bool {
        isServerSuperAdmin || serverTierKey == "platinum"
    }

    func serverDailyLimit(forTierKey tierKey: String? = nil) -> Int {
        let effectiveTierKey = normalizedTierKey(tierKey ?? serverTierKey)
        if isServerSuperAdmin { return Int.max }
        return tierConfigs[effectiveTierKey]?.daily_fetch_limit ?? 3
    }

    var currentServerDailyLimit: Int {
        serverDailyLimit()
    }

    // MARK: - Init

    init() {
        isCarfaxEnabled = UserDefaults.standard.object(forKey: carfaxEnabledKey) as? Bool ?? true
        // Load persisted state on first launch
        if let data = UserDefaults.standard.data(forKey: favKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            favorites = decoded
        }
        if let data = UserDefaults.standard.data(forKey: odoKey),
           let decoded = try? JSONDecoder().decode([String: OdoInfo].self, from: data) {
            // Migrate keys to normalized VINs on load
            var migrated: [String: OdoInfo] = [:]
            for (k, v) in decoded { migrated[normalizeVIN(k)] = v }
            odoByVIN = migrated
        }
        // Fetch tier config immediately — non-blocking, drives dynamic UI limits
        Task { await fetchTierConfigs() }
        Task { await fetchAppSettings() }
        nhtsaCacheObserver = NotificationCenter.default.addObserver(
            forName: .nhtsaCacheDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let update = notification.object as? NHTSACacheUpdate else { return }
            Task { @MainActor [weak self] in
                self?.applyNHTSACacheUpdate(update)
            }
        }
    }

    deinit {
        if let nhtsaCacheObserver {
            NotificationCenter.default.removeObserver(nhtsaCacheObserver)
        }
    }

    // MARK: - Local state mutations (called directly by HPDView for instant UI updates)

    func addFavoriteLocally(_ vin: String) {
        favorites.insert(vin)
        persistFavorites()
    }

    func removeFavoriteLocally(_ vin: String) {
        favorites.remove(vin)
        persistFavorites()
    }

    func setOdoInfo(_ info: OdoInfo, forVIN vin: String) {
        var sanitized = info
        sanitized.testDate = sanitized.testDate.dateOnly
        odoByVIN[vin] = sanitized
        persistOdo()
    }

    func clearOdoCache() {
        odoByVIN = [:]
        persistOdo()
    }

    func applyNHTSACacheUpdate(_ update: NHTSACacheUpdate) {
        let vin = normalizeVIN(update.vin)
        guard !vin.isEmpty else { return }

        if let make = update.make?.trimmingCharacters(in: .whitespacesAndNewlines), !make.isEmpty {
            decodedMakeByVIN[vin] = make
        }

        if let model = update.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            decodedModelByVIN[vin] = model
        }

        // Engine: "2.0L V4", "3.5L V6", etc.
        let dispStr: String? = {
            guard let d = update.engine_displacement_l?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !d.isEmpty, let num = Double(d) else { return nil }
            return String(format: "%.1fL", num)
        }()
        let cylStr: String? = {
            guard let c = update.engine_cylinders?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !c.isEmpty, let num = Int(c), num > 0 else { return nil }
            return "V\(num)"
        }()
        let engineStr: String?
        switch (dispStr, cylStr) {
        case let (d?, c?): engineStr = "\(d) \(c)"
        case let (d?, nil): engineStr = d
        case let (nil, c?): engineStr = c
        default: engineStr = nil
        }
        if let e = engineStr { engineByVIN[vin] = e }

        if let trim = update.trim?.trimmingCharacters(in: .whitespacesAndNewlines), !trim.isEmpty {
            trimByVIN[vin] = trim
        }

        if let bodyClass = update.body_class?.trimmingCharacters(in: .whitespacesAndNewlines), !bodyClass.isEmpty {
            bodyClassByVIN[vin] = bodyClass
        }

        if let cityMpg = update.city_mpg?.trimmingCharacters(in: .whitespacesAndNewlines), !cityMpg.isEmpty {
            cityMpgByVIN[vin] = cityMpg
        }

        if let hwyMpg = update.hwy_mpg?.trimmingCharacters(in: .whitespacesAndNewlines), !hwyMpg.isEmpty {
            hwyMpgByVIN[vin] = hwyMpg
        }
    }

    /// Strictly local browser/network cache wipe.
    /// Clears URLSession responses, all WKWebView persistent data (cookies, storage,
    /// IndexedDB, service workers), and the temp directory.
    /// DOES NOT touch user-saved data (odo readings, SPV values, favorites).
    func clearAppCache() {
        // 1. URLSession shared response cache
        URLCache.shared.removeAllCachedResponses()

        // 2. All WKWebView persistent data — critical for the hidden scraping WKWebView instances.
        //    Passing Date(timeIntervalSince1970: 0) removes data for all time.
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )

        // 3. Temporary directory files (downloaded previews, PDFs, etc.)
        let tmp = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }

        print("🧹 CACHE: Browser cache cleared (URLCache, WKWebView, tmp/) — user data untouched")
    }

    /// Wipes ALL user-specific state from memory and UserDefaults.
    /// Call this on sign-out and at the start of every fetch so a new user
    /// never sees a previous user's cached data ("ghost data" prevention).
    func clearAllLocalState() {
        favorites.removeAll()
        odoByVIN.removeAll()
        decodedMakeByVIN.removeAll()
        decodedModelByVIN.removeAll()
        engineByVIN.removeAll()
        trimByVIN.removeAll()
        bodyClassByVIN.removeAll()
        cityMpgByVIN.removeAll()
        hwyMpgByVIN.removeAll()
        currentProfile = nil
        currentTier = nil
        persistFavorites()   // write empty state to UserDefaults immediately
        persistOdo()
        print("🧹 SUPABASE: local state cleared")
    }

    // MARK: - Supabase Sync: Fetch

    /// Fetches all rows for the current user from `favorites_kbuck` and replaces local state.
    /// Clears state BEFORE the async call so a fetch failure never leaves ghost data on screen.
    func syncFetchFavoritesFromSupabase() async {
        guard let uid = currentUserID else {
            print("🔴 SUPABASE: syncFetchFavoritesFromSupabase — no authenticated user, aborting")
            return
        }

        do {
            let rows: [FavoriteRow] = try await supabase
                .from("favorites_kbuck")
                .select()
                .eq("user_id", value: uid.uuidString)   // explicit filter + RLS = belt-and-suspenders
                .execute()
                .value

            var newFavs: Set<String> = []
            var newOdoByVIN: [String: OdoInfo] = [:]
            for row in rows {
                let vin = normalizeVIN(row.vin)
                guard !vin.isEmpty else { continue }
                newFavs.insert(vin)

                let odometer = row.odometer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let testDate = row.test_date?.dateOnly ?? ""
                let privateValue = row.private_value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard !odometer.isEmpty || !testDate.isEmpty || !privateValue.isEmpty else { continue }

                newOdoByVIN[vin] = OdoInfo(
                    odometer: odometer,
                    testDate: testDate,
                    privateValue: privateValue.isEmpty ? nil : formatPrivateValueForDisplay(privateValue)
                )
            }
            favorites = newFavs
            odoByVIN = newOdoByVIN
            persistFavorites()
            persistOdo()

        } catch {
            print("🔴 SUPABASE ERROR in syncFetchFavoritesFromSupabase: \(error.localizedDescription)")
            print("🔴 Full error details: \(error)")
        }
    }

    // MARK: - Supabase Sync: Push all

    /// Replaces the entire `favorites` table with the given VIN list. Pass current `entries`
    /// from HPDView so vehicle metadata can be included in each row.
    func syncPushFavoritesToSupabase(_ vins: [String], entries: [HPDEntry]) async {
        let uid = currentUserID
        do {
            var rows: [FavoriteRow] = []
            for v in vins {
                let key  = normalizeVIN(v)
                let e    = entries.first(where: { normalizeVIN($0.vin) == key })
                let info = odoByVIN[key]
                rows.append(FavoriteRow(
                    user_id:       uid,
                    vin:           key,
                    year:          e.map { normalizedYear($0.year) },
                    make:          e?.make,
                    model:         e?.model,
                    odometer:      info?.odometer,
                    test_date:     info?.testDate.dateOnly,
                    private_value: info?.privateValue
                ))
            }

            if !rows.isEmpty {
                try await supabase.from("favorites_kbuck").upsert(rows).execute()
            } else {
            }

        } catch {
            print("🔴 SUPABASE ERROR in syncPushFavoritesToSupabase: \(error.localizedDescription)")
            print("🔴 Full error details: \(error)")
        }
    }

    // MARK: - Supabase Sync: Add single

    /// Upserts a single VIN (minimal row — no vehicle metadata).
    func syncAddFavorite(_ vin: String) {
        let clean = normalizeVIN(vin)
        let uid   = currentUserID   // capture sync before entering Task
        Task {
            do {
                let row = FavoriteRow(user_id: uid, vin: clean)
                try await supabase
                    .from("favorites_kbuck")
                    .upsert(row)
                    .execute()
                favorites.insert(clean)
                persistFavorites()
            } catch {
                print("🔴 SUPABASE ERROR in syncAddFavorite (VIN=\(clean)): \(error.localizedDescription)")
                print("🔴 Full error details: \(error)")
            }
        }
    }

    // MARK: - Supabase Sync: Remove single

    /// Deletes a single VIN row from `favorites`.
    func syncRemoveFavorite(_ vin: String) {
        let clean = normalizeVIN(vin)
        let uid = currentUserID
        Task {
            do {
                if let uid {
                    try await supabase
                        .from("favorites_kbuck")
                        .delete()
                        .eq("vin", value: clean)
                        .eq("user_id", value: uid.uuidString)
                        .execute()
                } else {
                    try await supabase
                        .from("favorites_kbuck")
                        .delete()
                        .eq("vin", value: clean)
                        .execute()
                }
                favorites.remove(clean)
                persistFavorites()
            } catch {
                print("🔴 SUPABASE ERROR in syncRemoveFavorite (VIN=\(clean)): \(error.localizedDescription)")
                print("🔴 Full error details: \(error)")
            }
        }
    }

    func syncCleanUpExpiredFavorites(activeVINs: Set<String>) {
        let expiredVINs = favorites.subtracting(activeVINs)
        guard !expiredVINs.isEmpty else { return }
        guard let uid = currentUserID else { return }

        Task(priority: .background) {
            do {
                let expiredArray = Array(expiredVINs)
                try await supabase
                    .from("favorites_kbuck")
                    .delete()
                    .eq("user_id", value: uid.uuidString)
                    .in("vin", values: expiredArray)
                    .execute()
                await MainActor.run {
                    self.favorites.subtract(expiredVINs)
                    for vin in expiredVINs { self.odoByVIN.removeValue(forKey: vin) }
                    self.persistFavorites()
                    self.persistOdo()
                }
            } catch {
                print("🔴 SUPABASE ERROR purging favorites: \\(error.localizedDescription)")
            }
        }
    }

    func syncLogLegalAgreement(vin: String) {
        let uid = currentUserID
        let cleanVIN = normalizeVIN(vin)
        Task(priority: .background) {
            do {
                let log = LegalAgreementLog(user_id: uid, vin: cleanVIN, action: "ACCEPTED_FETCH_TERMS")
                try await supabase.from("legal_agreements_log").insert(log).execute()
            } catch {
                print("🔴 SUPABASE ERROR logging agreement: \(error.localizedDescription)")
            }
        }
    }

    func pingActivityAndCheckBan() async -> Bool {
        do {
            let isBanned: Bool = try await supabase.rpc("ping_activity").execute().value
            return isBanned
        } catch {
            return false
        }
    }

    func syncToggleBan(userId: UUID, isBanned: Bool) async {
        do {
            try await supabase
                .rpc("toggle_user_ban", params: ["target_user_id": userId.uuidString, "ban_status": isBanned ? "true" : "false"])
                .execute()
        } catch {
            print("🔴 RPC Error toggling ban: \(error)")
        }
    }

    // MARK: - Supabase Sync: Upsert full detail

    /// Upserts a full-detail row including odometer and private value from the local cache.
    func syncUpsertFavorite(entry e: HPDEntry) {
        let vin  = normalizeVIN(e.vin)
        let uid  = currentUserID   // capture sync before entering Task
        let info = odoByVIN[vin]
        let row  = FavoriteRow(
            user_id:       uid,
            vin:           vin,
            year:          normalizedYear(e.year),
            make:          e.make,
            model:         e.model,
            odometer:      info?.odometer,
            test_date:     info?.testDate,
            private_value: info?.privateValue
        )
        Task {
            do {
                try await supabase
                    .from("favorites_kbuck")
                    .upsert(row)
                    .execute()
                await syncFetchFavoritesFromSupabase()
            } catch {
                print("🔴 SUPABASE ERROR in syncUpsertFavorite (VIN=\(vin)): \(error.localizedDescription)")
                print("🔴 Full error details: \(error)")
            }
        }
    }

    // MARK: - Persistence

    private func persistFavorites() {
        UserDefaults.standard.set(try? JSONEncoder().encode(favorites), forKey: favKey)
    }

    private func persistOdo() {
        UserDefaults.standard.set(try? JSONEncoder().encode(odoByVIN), forKey: odoKey)
    }

    // MARK: - Global VIN Quick Data Cache

    private func quickDataInfo(from row: QuickDataCacheRow) -> OdoInfo? {
        let odometer = row.odometer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let testDate = row.test_date?.dateOnly ?? ""
        let privateValue = row.private_value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let realModel = row.real_model?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !odometer.isEmpty, !privateValue.isEmpty else { return nil }

        return OdoInfo(
            odometer: odometer,
            testDate: testDate,
            privateValue: formatPrivateValueForDisplay(privateValue),
            realModel: realModel?.isEmpty == false ? realModel : nil
        )
    }

    func loadQuickDataCacheFromSupabase(forVIN vin: String) async -> Bool {
        let cleanVIN = normalizeVIN(vin)
        guard !cleanVIN.isEmpty else { return false }

        do {
            let rows: [QuickDataCacheRow] = try await supabase
                .rpc("get_quick_data_cache", params: ["target_vin": cleanVIN])
                .execute()
                .value

            guard let row = rows.first, let info = quickDataInfo(from: row) else {
                return false
            }

            setOdoInfo(info, forVIN: cleanVIN)
            print("✅ QUICK DATA CACHE: Loaded cached quick data for \(cleanVIN)")
            return true
        } catch {
            print("🔴 QUICK DATA CACHE: load failed for \(cleanVIN): \(error)")
            return false
        }
    }

    func saveQuickDataCacheToSupabase(forVIN vin: String) async {
        let cleanVIN = normalizeVIN(vin)
        guard !cleanVIN.isEmpty else { return }
        guard let info = odoByVIN[cleanVIN] else { return }

        let odometer = info.odometer.trimmingCharacters(in: .whitespacesAndNewlines)
        let testDate = info.testDate.dateOnly
        let privateValue = info.privateValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let realModel = info.realModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !odometer.isEmpty, !privateValue.isEmpty else { return }

        do {
            _ = try await supabase.rpc(
                "upsert_quick_data_cache",
                params: [
                    "target_vin": cleanVIN,
                    "target_odometer": odometer,
                    "target_test_date": testDate,
                    "target_private_value": privateValue,
                    "target_real_model": realModel
                ]
            ).execute()
            print("✅ QUICK DATA CACHE: Saved quick data for \(cleanVIN)")
        } catch {
            print("🔴 QUICK DATA CACHE: save failed for \(cleanVIN): \(error)")
        }
    }

    // MARK: - Remote Tier Config

    /// Fetches subscription_tiers_kbuck and populates tierConfigs.
    /// Called on init and again whenever Settings or PaywallView opens
    /// to guarantee limits are always in sync with the database.
    func fetchTierConfigs() async {
        do {
            let rows: [TierConfig] = try await supabase
                .from("subscription_tiers_kbuck")
                .select()
                .execute()
                .value
            let mapped = Dictionary(uniqueKeysWithValues: rows.map { ($0.tier_name, $0) })
            tierConfigs = mapped
            print("✅ TIER CONFIGS: Loaded \(mapped.count) tier(s) from remote")
        } catch {
            print("🔴 fetchTierConfigs failed: \(error)")
        }
    }

    func fetchAppSettings() async {
        do {
            let row: AppSettingsRow = try await supabase
                .from("app_settings_kbuck")
                .select("carfax_enabled")
                .eq("id", value: 1)
                .single()
                .execute()
                .value

            let isEnabled = row.carfax_enabled ?? true
            isCarfaxEnabled = isEnabled
            UserDefaults.standard.set(isEnabled, forKey: carfaxEnabledKey)
            print("✅ APP SETTINGS: Carfax enabled = \(isEnabled)")
        } catch {
            print("🔴 fetchAppSettings failed: \(error)")
        }
    }

    func setCarfaxEnabled(_ isEnabled: Bool) async throws {
        try await supabase
            .rpc("set_carfax_enabled", params: ["new_value": isEnabled ? "true" : "false"])
            .execute()
        await fetchAppSettings()
    }

    // MARK: - User Usage Profile

    func fetchCurrentProfile() async {
        do {
            let profiles: [UserUsageProfile] = try await supabase.rpc("get_my_usage_profile").execute().value
            let fetchedProfile = profiles.first
            let fetchedTier = fetchedProfile?.plan_tier
            await MainActor.run {
                print("DEBUG DASHBOARD: Current user profile fetched.")
                print("DEBUG DASHBOARD: -> Real Tier is: \(fetchedTier ?? "NIL")")
                self.currentProfile = fetchedProfile
                self.currentTier = fetchedTier?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            print("🔴 fetchCurrentProfile failed: \(error)")
        }
    }

    func syncCurrentUserAppVersion() async {
        guard let user = supabase.auth.currentUser else { return }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

        do {
            try await supabase
                .from("profiles_kbuck")
                .update(["app_version": appVersion])
                .eq("id", value: user.id.uuidString)
                .execute()
        } catch {
            print("🔴 app_version sync failed: \(error)")
        }
    }

    // MARK: - Extraction Rate Limiting (Supabase-backed)

    func checkExtractionLimits(vin: String) async -> RateLimitResponse {
        do {
            return try await supabase.rpc("can_extract_data", params: ["target_vin": vin]).execute().value
        } catch {
            print("🔴 Limit check failed: \(error)")
            return RateLimitResponse(allowed: false, reason: "Quota validation unavailable. Please try again.")
        }
    }

    func recordExtractionUsage(vin: String) {
        Task(priority: .background) {
            _ = try? await supabase.rpc("increment_fetch_count", params: ["target_vin": normalizeVIN(vin)]).execute()
        }
    }

    /// Increments daily and lifetime counters via a single DB RPC.
    /// Server-side SQL is the source of truth for role, plan, and quota enforcement.
    func incrementQuota(vin: String) async {
        guard supabase.auth.currentUser != nil else { return }

        do {
            try await supabase
                .rpc("increment_fetch_count", params: ["target_vin": normalizeVIN(vin)])
                .execute()
            await fetchCurrentProfile()
        } catch {
            print("🔴 QUOTA: increment_fetch_count failed: \(error)")
        }
    }

    func resetUserLimits(userId: UUID) async {
        _ = try? await supabase.rpc("reset_user_limits", params: ["target_user_id": userId.uuidString]).execute()
    }

    // MARK: - NHTSA Cache: on-demand loader from global_vin_cache_kbuck

    /// Loads decoded vehicle data (make, model, engine) for a single VIN from
    /// global_vin_cache_kbuck (populated by the server-side hpd-pipeline Edge Function).
    /// Skips the network call only if BOTH make AND model are already in memory.
    func loadNHTSACacheForVIN(_ vin: String) async {
        let cleanVIN = normalizeVIN(vin)
        guard !cleanVIN.isEmpty else { return }

        // Only skip if we already have both make and model — engine alone is not enough.
        if decodedMakeByVIN[cleanVIN] != nil && decodedModelByVIN[cleanVIN] != nil { return }

        do {
            let rows: [NHTSACacheUpdate] = try await supabase
                .from("global_vin_cache_kbuck")
                .select()
                .eq("vin", value: cleanVIN)
                .limit(1)
                .execute()
                .value
            if let row = rows.first {
                let make  = row.make?.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = row.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                let year  = row.year
                print("✅ [SupabaseCache] VIN \(cleanVIN) → \(make ?? "?") \(model ?? "?") \(year ?? 0)")
                applyNHTSACacheUpdate(row)
            } else {
                print("⚠️ [SupabaseCache] No cache row found for VIN \(cleanVIN)")
            }
        } catch {
            print("🔴 NHTSA CACHE: loadNHTSACacheForVIN failed for \(cleanVIN): \(error)")
        }
    }

    /// Bulk preloads decoded vehicle data from global_vin_cache_kbuck so cards render
    /// with stable titles/details on first appearance instead of repainting as each VIN loads.
    func preloadNHTSACacheForVINs(_ vins: [String]) async {
        let uniqueVINs = Array(Set(vins.map(normalizeVIN))).filter { !$0.isEmpty }
        guard !uniqueVINs.isEmpty else { return }

        let missingVINs = uniqueVINs.filter { vin in
            decodedMakeByVIN[vin] == nil || decodedModelByVIN[vin] == nil
        }
        guard !missingVINs.isEmpty else { return }

        let batchSize = 100
        for start in stride(from: 0, to: missingVINs.count, by: batchSize) {
            let batch = Array(missingVINs[start..<min(start + batchSize, missingVINs.count)])

            do {
                let rows: [NHTSACacheUpdate] = try await supabase
                    .from("global_vin_cache_kbuck")
                    .select()
                    .in("vin", values: batch)
                    .execute()
                    .value

                for row in rows {
                    applyNHTSACacheUpdate(row)
                }
            } catch {
                print("🔴 NHTSA CACHE: bulk preload failed for batch size \(batch.count): \(error)")
            }
        }
    }
}
