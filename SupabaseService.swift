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
let supabase = SupabaseClient(
    supabaseURL: URL(string: "https://tnescuqegmehazuffmte.supabase.co")!,
    supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRuZXNjdXFlZ21laGF6dWZmbXRlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM2OTI4ODEsImV4cCI6MjA4OTI2ODg4MX0.LszstZi962himWPuoSWEXR9Xzhbl2ncewJSGzTnoeIg",
    options: SupabaseClientOptions(auth: SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true))
)



// MARK: - Rate Limit Response

struct RateLimitResponse: Codable {
    let allowed: Bool
    let reason: String?
}

// MARK: - User Usage Profile

struct UserUsageProfile: Codable {
    let scrape_count_today: Int
    let last_scrape_reset: String?
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

// MARK: - Service

@MainActor final class SupabaseService: ObservableObject {

    // Published state — HPDView observes these directly
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var odoByVIN: [String: OdoInfo] = [:]
    @Published private(set) var currentProfile: UserUsageProfile? = nil

    // UserDefaults keys (same as the old @AppStorage keys so data migrates automatically)
    private let favKey  = "hpdFavorites"
    private let odoKey  = "hpdOdoCache"

    /// Synchronous shortcut — currentUser is backed by in-memory session, zero network cost.
    private var currentUserID: UUID? { supabase.auth.currentUser?.id }

    // MARK: - Init

    init() {
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

        print("🔵 SUPABASE: syncFetchFavoritesFromSupabase — starting fetch for uid=\(uid)…")
        do {
            let rows: [FavoriteRow] = try await supabase
                .from("favorites_kbuck")
                .select()
                .eq("user_id", value: uid.uuidString)   // explicit filter + RLS = belt-and-suspenders
                .execute()
                .value

            print("🟢 SUPABASE SUCCESS: syncFetchFavoritesFromSupabase — received \(rows.count) row(s)")

            var newFavs: Set<String> = []
            for row in rows {
                let vin = normalizeVIN(row.vin)
                guard !vin.isEmpty else { continue }
                newFavs.insert(vin)

                var info = odoByVIN[vin] ?? OdoInfo(odometer: "", testDate: "", privateValue: nil)
                if let odo = row.odometer, !odo.isEmpty { info.odometer = odo }
                if let td = row.test_date, !td.isEmpty { info.testDate = td.dateOnly }
                if let pv = row.private_value, !pv.isEmpty { info.privateValue = formatPrivateValueForDisplay(pv) }
                odoByVIN[vin] = info
            }
            favorites = newFavs
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
        print("🔵 SUPABASE: syncPushFavoritesToSupabase — pushing \(vins.count) VIN(s)…")
        do {
            // Delete every existing row first
            try await supabase
                .from("favorites_kbuck")
                .delete()
                .neq("vin", value: "")
                .execute()

            print("🟡 SUPABASE INFO: syncPushFavoritesToSupabase — cleared existing rows")

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
                try await supabase.from("favorites_kbuck").insert(rows).execute()
                print("🟢 SUPABASE SUCCESS: syncPushFavoritesToSupabase — inserted \(rows.count) row(s)")
            } else {
                print("🟡 SUPABASE INFO: syncPushFavoritesToSupabase — nothing to push (empty list)")
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
        print("🔵 SUPABASE: syncAddFavorite — VIN=\(clean)")
        Task {
            do {
                let row = FavoriteRow(user_id: uid, vin: clean)
                try await supabase
                    .from("favorites_kbuck")
                    .upsert(row)
                    .execute()
                print("🟢 SUPABASE SUCCESS: syncAddFavorite — VIN=\(clean) upserted")
                await syncFetchFavoritesFromSupabase()
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
        print("🔵 SUPABASE: syncRemoveFavorite — VIN=\(clean)")
        Task {
            do {
                try await supabase
                    .from("favorites_kbuck")
                    .delete()
                    .eq("vin", value: clean)
                    .execute()
                print("🟢 SUPABASE SUCCESS: syncRemoveFavorite — VIN=\(clean) deleted")
                await syncFetchFavoritesFromSupabase()
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
                print("🟢 SUPABASE SUCCESS: Purged \\(expiredVINs.count) expired favorites.")

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
                print("🟢 SUPABASE SUCCESS: Legal agreement logged for VIN=\(cleanVIN)")
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
        print("🔵 SUPABASE: syncUpsertFavorite — VIN=\(vin) (\(normalizedYear(e.year)) \(e.make) \(e.model))")
        Task {
            do {
                try await supabase
                    .from("favorites_kbuck")
                    .upsert(row)
                    .execute()
                print("🟢 SUPABASE SUCCESS: syncUpsertFavorite — VIN=\(vin) upserted with full detail")
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

    // MARK: - User Usage Profile

    func fetchCurrentProfile() async {
        do {
            let profiles: [UserUsageProfile] = try await supabase.rpc("get_my_usage_profile").execute().value
            await MainActor.run { self.currentProfile = profiles.first }
        } catch {
            print("🔴 fetchCurrentProfile failed: \(error)")
        }
    }

    // MARK: - Extraction Rate Limiting (Supabase-backed)

    func checkExtractionLimits(vin: String) async -> RateLimitResponse {
        do {
            return try await supabase.rpc("can_extract_data", params: ["target_vin": vin]).execute().value
        } catch {
            print("🔴 Limit check failed: \(error)")
            return RateLimitResponse(allowed: true, reason: nil) // Fail open on network errors
        }
    }

    func recordExtractionUsage(vin: String) {
        Task(priority: .background) {
            _ = try? await supabase.rpc("record_data_extraction", params: ["target_vin": vin]).execute()
        }
    }

    /// Increments the daily quota counter via the timezone-aware RPC.
    /// Super Admins are exempt — this function returns immediately without touching the DB.
    func incrementQuota() async {
        guard let user = supabase.auth.currentUser else { return }

        // Read role from UserDefaults (written at login by KbuckApp / LoginView)
        let role = UserDefaults.standard.string(forKey: "userRole") ?? "user"
        guard role != "super_admin" else {
            print("🔵 QUOTA: super_admin — skipping increment_user_quota")
            return
        }

        do {
            try await supabase
                .rpc("increment_user_quota", params: ["user_uuid": user.id.uuidString])
                .execute()
            print("🟢 QUOTA: increment_user_quota succeeded for uid=\(user.id)")
            await fetchCurrentProfile()
        } catch {
            print("🔴 QUOTA: increment_user_quota failed: \(error)")
        }
    }

    func resetUserLimits(userId: UUID) async {
        _ = try? await supabase.rpc("reset_user_limits", params: ["target_user_id": userId.uuidString]).execute()
    }
}
