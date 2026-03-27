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
        // Wipe memory + UserDefaults first — even a network failure leaves a clean slate.
        clearAllLocalState()

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
            var newOdo: [String: OdoInfo] = [:]   // start empty — never carry stale data forward

            for row in rows {
                let vin = normalizeVIN(row.vin)
                guard !vin.isEmpty else { continue }
                newFavs.insert(vin)
                let pvFormatted = row.private_value.map { formatPrivateValueForDisplay($0) }
                newOdo[vin] = OdoInfo(
                    odometer: row.odometer ?? "",
                    testDate: (row.test_date ?? "").dateOnly,
                    privateValue: pvFormatted
                )
            }

            favorites = newFavs
            odoByVIN  = newOdo
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
                    .upsert(row, onConflict: "user_id,vin")
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
                    .upsert(row, onConflict: "user_id,vin")
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
}
