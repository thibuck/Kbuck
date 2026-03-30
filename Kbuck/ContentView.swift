
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

// UIKit-level tap recognizer with cancelsTouchesInView = false.
// This dismisses the keyboard without ever consuming or cancelling the
// original touch, so buttons and NavigationLinks respond on the first tap.
private struct KeyboardDismissBackground: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.dismiss)
        )
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject {
        @objc func dismiss() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }
}

extension View {
    func hideKeyboardOnTap() -> some View {
        background(KeyboardDismissBackground())
    }
}

// MARK: - Auth Router

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var isAuthenticated = false
    @State private var isAuthReady     = false
    @State private var didBootstrapFavorites = false
    @State private var showInitialPaywall: Bool = false
    @AppStorage("hpdRefreshTrigger") private var hpdRefreshTrigger: Int = 0
    @AppStorage("hpdUserBanned")          private var isUserBanned: Bool = false
    @AppStorage("hasSeenInitialPaywall")  private var hasSeenInitialPaywall: Bool = false

    // Persisted role — written here on sign-in, read everywhere else.
    // Defaults to "user" so no privileged UI is ever shown before the fetch resolves.
    @AppStorage("userRole") private var userRole: String = "user"

    // Shared across all tabs — prevents duplicate network calls and keeps state in sync.
    @StateObject private var supabaseService = SupabaseService()

    // Cross-tab routing state — elevated here so HomeSummaryView and HPDView share a single source of truth.
    @State private var selectedTab: Int = 0
    @State private var crossTabLocationFilter: String? = nil

    var body: some View {
        Group {
            if !isAuthReady {
                ProgressView()
            } else if isAuthenticated {
                TabView(selection: $selectedTab) {
                    HomeSummaryView(selectedTab: $selectedTab, targetLocationFilter: $crossTabLocationFilter)
                        .tabItem { Label("Dashboard", systemImage: "chart.bar.xaxis") }
                        .tag(0)
                    HPDView(externalLocationFilter: $crossTabLocationFilter)
                        .tabItem { Label("HPD AUCTION", systemImage: "car.fill") }
                        .tag(1)
                    HPDView(favoritesOnly: true, externalLocationFilter: .constant(nil))
                        .tabItem { Label("FAVORITES", systemImage: "star.fill") }
                        .tag(2)
                    HPDSettingsView()
                        .tabItem { Label("SETTINGS", systemImage: "gearshape.fill") }
                        .tag(3)
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
                    if session != nil {
                        if !didBootstrapFavorites {
                            await supabaseService.syncFetchFavoritesFromSupabase()
                            didBootstrapFavorites = true
                        }
                        fetchRole()
                        runGlobalLifecycleSync()
                        if !hasSeenInitialPaywall && userRole != "super_admin" {
                            hasSeenInitialPaywall = true
                            showInitialPaywall = true
                        }
                    }
                case .signedIn:
                    isAuthenticated = true
                    if !didBootstrapFavorites {
                        await supabaseService.syncFetchFavoritesFromSupabase()
                        didBootstrapFavorites = true
                    }
                    fetchRole()
                    runGlobalLifecycleSync()
                    if !hasSeenInitialPaywall && userRole != "super_admin" {
                        hasSeenInitialPaywall = true
                        showInitialPaywall = true
                    }
                case .signedOut, .userDeleted:
                    isAuthenticated = false
                    didBootstrapFavorites = false
                    isUserBanned = false
                    userRole = "user"   // clear role so no stale admin access persists
                default:
                    break
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, isAuthenticated else { return }
            runGlobalLifecycleSync()
            hpdRefreshTrigger += 1
        }
        .sheet(isPresented: $showInitialPaywall) {
            PaywallView()
        }
        .hideKeyboardOnTap()
    }

    // MARK: - Role fetch

    /// Reads the current user's `role` from `profiles_kbuck`.
    /// RLS guarantees only the authenticated user's own row is returned.
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
            } catch {
                // Profile row may not yet exist on first sign-in before the trigger fires.
                // Fall back to "user" — the trigger will have created the row by next launch.
                userRole = "user"
                print("🔴 RBAC: role fetch failed — defaulting to 'user': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Global Lifecycle Sync
    private func runGlobalLifecycleSync() {
        Task {
            let banned = await supabaseService.pingActivityAndCheckBan()
            isUserBanned = banned
            if banned {
                supabaseService.clearAllLocalState()
                try? await supabase.auth.signOut()
                isAuthenticated = false
                userRole = "user"
            }
        }
    }
}
