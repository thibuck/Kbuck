
//
//  ContentView.swift
//  Kbuck
//

import SwiftUI
import Supabase

extension Bundle {
    var appVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0" }
    var buildNumber: String { (infoDictionary?["CFBundleVersion"] as? String) ?? "1" }
    var versionLabel: String { "v\(appVersion) (\(buildNumber))" }
}

extension View {
    func hideKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }
}

// MARK: - Auth Router

struct ContentView: View {
    @State private var isAuthenticated = false
    @State private var isAuthReady     = false

    // Persisted role — written here on sign-in, read in HPDSettingsView (and anywhere else).
    // Defaults to "user" so no privileged UI is ever shown before the fetch resolves.
    @AppStorage("userRole") private var userRole: String = "user"

    // Shared across all tabs — prevents duplicate network calls and keeps state in sync.
    @StateObject private var supabaseService = SupabaseService()

    var body: some View {
        Group {
            if !isAuthReady {
                ProgressView()
            } else if isAuthenticated {
                TabView {
                    HPDView()
                        .tabItem { Label("HPD AUCTION", systemImage: "car.fill") }
                    HPDView(favoritesOnly: true)
                        .tabItem { Label("FAVORITES", systemImage: "star.fill") }
                    HPDSettingsView()
                        .tabItem { Label("SETTINGS", systemImage: "gearshape.fill") }
                }
                .environmentObject(supabaseService)
            } else {
                LoginView()
            }
        }
        // authStateChanges is nonisolated and always emits .initialSession first,
        // so this single stream drives both the launch-time check and ongoing changes.
        .task {
            for await (event, session) in supabase.auth.authStateChanges {
                switch event {
                case .initialSession:
                    isAuthenticated = session != nil
                    isAuthReady     = true
                    if session != nil { fetchRole() }
                case .signedIn:
                    isAuthenticated = true
                    fetchRole()
                case .signedOut, .userDeleted:
                    isAuthenticated = false
                    userRole = "user"   // clear role so no stale admin access persists
                default:
                    break
                }
            }
        }
        .hideKeyboardOnTap()
    }

    // MARK: - Role fetch

    /// Reads the current user's `role` from the `profiles` table.
    /// RLS guarantees only the authenticated user's own row is returned,
    /// so no `.eq` filter is required — `.single()` is sufficient.
    private func fetchRole() {
        Task {
            do {
                struct ProfileRow: Decodable { let role: String }
                let row: ProfileRow = try await supabase
                    .from("profiles_kbuck")
                    .select("role")
                    .single()
                    .execute()
                    .value
                userRole = row.role
                print("🟢 RBAC: role fetched → \(row.role)")
            } catch {
                // Profile row may not yet exist on first sign-in before the trigger fires.
                // Fall back to "user" — the trigger will have created the row by next launch.
                userRole = "user"
                print("🔴 RBAC: role fetch failed — defaulting to 'user': \(error.localizedDescription)")
            }
        }
    }
}
