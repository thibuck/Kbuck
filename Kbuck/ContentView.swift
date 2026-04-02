
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
    private let defaultHPDURLString = "https://www.houstontx.gov/police/auto_dealers_detail/Vehicles_Scheduled_For_Auction.htm"

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var carfaxVault = CarfaxVault.shared

    @State private var isAuthenticated = false
    @State private var isAuthReady     = false
    @State private var didBootstrapFavorites = false
    @State private var showInitialPaywall: Bool = false
    @State private var isPreloadingHPDCache = false
    @AppStorage("hpdRefreshTrigger") private var hpdRefreshTrigger: Int = 0
    @AppStorage("hpdUserBanned")          private var isUserBanned: Bool = false
    @AppStorage("hasSeenInitialPaywall")  private var hasSeenInitialPaywall: Bool = false
    @AppStorage("hpdCachedEntries")       private var hpdCachedEntriesData: Data = Data()
    @AppStorage("hpdCachedURL")           private var hpdCachedURL: String = ""
    @AppStorage("hpdLastFetchTS")         private var hpdLastFetchTS: Double = 0
    @AppStorage("lastHPDSyncDate")        private var lastHPDSyncDate: Double = 0
    @AppStorage("hpdHadLastError")        private var hpdHadLastError: Bool = false
    @AppStorage("hpdManualURLEnabled")    private var manualURLModeEnabled: Bool = false
    @AppStorage("hpdManualURLInput")      private var hpdManualURLInput: String = ""
    @AppStorage("nhtsaDecodedCount")      private var storedDecodedCount: Int = 0
    @AppStorage("nhtsaTotalToDecode")     private var storedTotalToDecode: Int = 0
    @AppStorage("nhtsaIsDecoding")        private var storedIsDecoding: Bool = false

    // Persisted role — written here on sign-in, read everywhere else.
    // Defaults to "user" so no privileged UI is ever shown before the fetch resolves.
    @AppStorage("userRole") private var userRole: String = "user"

    // Shared service injected at app root so sheets and all branches receive it safely.
    @EnvironmentObject private var supabaseService: SupabaseService

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
                        .tabItem { Label("HOME", systemImage: "car.circle.fill") }
                        .tag(0)
                    // Temporarily hidden from the app UI, but kept in code for later reuse.
                    // HPDView(externalLocationFilter: $crossTabLocationFilter)
                    //     .tabItem { Label("HPD AUCTION", systemImage: "car.fill") }
                    //     .tag(1)
                    HPDView(favoritesOnly: true, externalLocationFilter: .constant(nil))
                        .tabItem { Label("FAVORITES", systemImage: "star.fill") }
                        .tag(2)
                    if !carfaxVault.savedReports.isEmpty {
                        CarfaxVaultView()
                            .tabItem { Label("MY REPORTS", systemImage: "doc.text.fill") }
                            .tag(3)
                    }
                    HPDSettingsView()
                        .tabItem { Label("SETTINGS", systemImage: "gearshape.fill") }
                        .tag(4)
                }
            } else {
                LoginView()
            }
        }
        .environmentObject(supabaseService)
        // authStateChanges is nonisolated and always emits .initialSession first,
        // so this single stream drives both the launch-time check and ongoing changes.
        .task {
            for await (event, session) in supabase.auth.authStateChanges {
                switch event {
                case .initialSession:
                    isAuthenticated = session != nil
                    isAuthReady     = true
                    if session != nil {
                        await supabaseService.fetchAppSettings()
                        await supabaseService.fetchCurrentProfile()
                        await supabaseService.syncCurrentUserAppVersion()
                        if !didBootstrapFavorites {
                            await supabaseService.syncFetchFavoritesFromSupabase()
                            didBootstrapFavorites = true
                        }
                        fetchRole()
                        runGlobalLifecycleSync()
                        await preloadHPDAuctionDataIfNeeded()
                        if !hasSeenInitialPaywall && userRole != "super_admin" {
                            hasSeenInitialPaywall = true
                            showInitialPaywall = true
                        }
                    }
                case .signedIn:
                    isAuthenticated = true
                    await supabaseService.fetchAppSettings()
                    await supabaseService.fetchCurrentProfile()
                    await supabaseService.syncCurrentUserAppVersion()
                    if !didBootstrapFavorites {
                        await supabaseService.syncFetchFavoritesFromSupabase()
                        didBootstrapFavorites = true
                    }
                    fetchRole()
                    runGlobalLifecycleSync()
                    await preloadHPDAuctionDataIfNeeded(force: true)
                    if !hasSeenInitialPaywall && userRole != "super_admin" {
                        hasSeenInitialPaywall = true
                        showInitialPaywall = true
                    }
                case .signedOut, .userDeleted:
                    isAuthenticated = false
                    didBootstrapFavorites = false
                    isUserBanned = false
                    supabaseService.clearAllLocalState()
                    userRole = "user"   // clear role so no stale admin access persists
                default:
                    break
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, isAuthenticated else { return }
            Task {
                await supabaseService.fetchAppSettings()
                runGlobalLifecycleSync()
                await preloadHPDAuctionDataIfNeeded()
                hpdRefreshTrigger += 1
            }
        }
        // Pull-to-refresh (and any other hpdRefreshTrigger increment) must also
        // force-refresh hpdCachedEntriesData so HomeSummaryView sees new data.
        .onChange(of: hpdRefreshTrigger) { _, _ in
            guard isAuthenticated else { return }
            Task {
                await preloadHPDAuctionDataIfNeeded(force: true)
            }
        }
        .sheet(isPresented: $showInitialPaywall) {
            PaywallView()
        }
        .onChange(of: supabaseService.isCarfaxEnabled) { _, isEnabled in
            if !isEnabled, selectedTab == 3 {
                selectedTab = 0
            }
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

    private func preloadHPDAuctionDataIfNeeded(force: Bool = false) async {
        guard !isPreloadingHPDCache else { return }

        let sourceURLString: String
        if manualURLModeEnabled, !hpdManualURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sourceURLString = hpdManualURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sourceURLString = defaultHPDURLString
        }

        let isDefaultSource = sourceURLString == defaultHPDURLString
        let alreadySyncedToday = Calendar.current.isDateInToday(Date(timeIntervalSince1970: lastHPDSyncDate))
        if !force, isDefaultSource, alreadySyncedToday, !hpdCachedEntriesData.isEmpty {
            return
        }

        guard let url = URL(string: sourceURLString) else { return }

        isPreloadingHPDCache = true
        defer { isPreloadingHPDCache = false }

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 60
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return
            }

            let validEntries = HPDParser.parse(raw)
                .filter { !isDateInPast($0.dateScheduled) }
                .map { entry in
                    var normalized = entry
                    if let normalizedDate = HPDParser.normalizeUSDate(entry.dateScheduled) {
                        normalized.dateScheduled = normalizedDate
                    }
                    return normalized
                }

            guard !validEntries.isEmpty, let encoded = try? JSONEncoder().encode(validEntries) else {
                return
            }

            // [NHTSA-LOCAL DISABLED] Vehicle names now come from global_vin_cache_kbuck
            // via the server-side hpd-pipeline Edge Function. No client-side NHTSA calls needed.
            // let scrapedVehicles = validEntries.map { entry in
            //     NHTSAScrapedVehicle(vin: entry.vin)
            // }

            hpdCachedEntriesData = encoded
            hpdCachedURL = sourceURLString
            hpdLastFetchTS = Date().timeIntervalSince1970
            lastHPDSyncDate = Date().timeIntervalSince1970
            hpdHadLastError = false

            // Task(priority: .background) {
            //     let pipeline = NHTSADecoderPipeline()
            //     await MainActor.run {
            //         beginDecodingProgress(total: scrapedVehicles.count)
            //     }
            //     await pipeline.decodeAndCache(scrapedVehicles) { current, total in
            //         self.updateDecodingProgress(current: current, total: total)
            //     }
            //     await MainActor.run {
            //         finishDecodingProgress()
            //     }
            // }
        } catch {
            print("🔴 HPD preload failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func beginDecodingProgress(total: Int) {
        storedDecodedCount = 0
        storedTotalToDecode = total
        storedIsDecoding = total > 0
    }

    @MainActor
    private func updateDecodingProgress(current: Int, total: Int) {
        storedDecodedCount = current
        storedTotalToDecode = total
        storedIsDecoding = total > 0 && current < total
    }

    @MainActor
    private func finishDecodingProgress() {
        storedDecodedCount = storedTotalToDecode
        storedIsDecoding = false
    }
}
