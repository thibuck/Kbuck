import SwiftUI
import Supabase
import StoreKit

struct AdminUserStatus: Codable, Identifiable {
    let id: UUID
    let email: String?
    let last_active: String?
    let is_banned: Bool?
    let scrape_count_today: Int?
    let last_scrape_reset: String?
    let total_fetches: Int?
    let role: String?
    let app_version: String?

    var displayTime: String {
        guard let raw = last_active else { return "Never" }
        let cleanStr = raw.replacingOccurrences(of: " ", with: "T")
        var date: Date? = nil
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = isoFormatter.date(from: cleanStr)
        if date == nil {
            isoFormatter.formatOptions = [.withInternetDateTime]
            date = isoFormatter.date(from: cleanStr)
        }
        if date == nil {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ"] {
                df.dateFormat = format
                if let parsed = df.date(from: cleanStr) { date = parsed; break }
            }
        }
        guard let validDate = date else { return "Format Error" }
        let diff = Date().timeIntervalSince(validDate)
        if diff >= -60 && diff < 300 { return "🟢 Online" }
        let relFormatter = RelativeDateTimeFormatter()
        relFormatter.unitsStyle = .abbreviated
        return relFormatter.localizedString(for: validDate, relativeTo: Date())
    }
}

// MARK: - Legal Terms

struct LegalTermsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Terms & Conditions")
                        .font(.title2.bold())

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Data Source Disclaimer")
                            .font(.headline)
                        Text("Vehicle-related data, including inspection date, reported mileage, and estimated DMV Private Value, may be retrieved from public third-party sources. This information is provided strictly for informational purposes and may not reflect current conditions.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Warranties")
                            .font(.headline)
                        Text("All information is provided 'AS IS' and 'AS AVAILABLE' without warranties of any kind, express or implied, including but not limited to accuracy, completeness, reliability, fitness for a particular purpose, merchantability, or non-infringement.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Limitation of Liability")
                            .font(.headline)
                        Text("By using this app and proceeding with data retrieval, you acknowledge and agree that the app provider is not responsible for any losses, damages, claims, or decisions arising from reliance on third-party data. You assume full responsibility for independently verifying all information before taking any action.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Legal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Admin User Detail Sheet

struct AdminUserDetailSheet: View {
    let user: AdminUserStatus
    let supabaseService: SupabaseService
    let currentUserID: UUID?
    let onActionComplete: () -> Void
    @Environment(\.dismiss) var dismiss

    // MARK: Confirmation alert state
    @State private var isShowingConfirmAlert  = false
    @State private var confirmTitle           = ""
    @State private var confirmMessage         = ""
    @State private var confirmIsDestructive   = true
    @State private var confirmationAction: (() -> Void)? = nil

    private var isSelf: Bool { currentUserID == user.id }

    private func schedule(title: String, message: String, destructive: Bool = true, action: @escaping () -> Void) {
        confirmTitle         = title
        confirmMessage       = message
        confirmIsDestructive = destructive
        confirmationAction   = action
        isShowingConfirmAlert = true
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: User Identity
                Section(header: Text("User Identity")) {
                    LabeledContent("Email", value: user.email ?? "Unknown")
                    LabeledContent("Last Active", value: user.displayTime)
                    LabeledContent("App Version", value: user.app_version ?? "N/A")
                    if user.is_banned == true {
                        Text("Account is currently BANNED")
                            .foregroundStyle(.red)
                            .font(.caption.bold())
                    }
                }

                // MARK: Quota / Role
                if user.role == "super_admin" {
                    Section(header: Text("Account Type")) {
                        LabeledContent("Role", value: "Super Admin")
                        LabeledContent("Quota", value: "Unlimited — exempt from daily limits")
                    }
                } else {
                    Section(header: Text("Quota Usage")) {
                        let count = user.scrape_count_today ?? 0
                        ProgressView(value: Double(count), total: 50.0) {
                            Text("Daily Usage: \(count) / 50 today")
                                .font(.subheadline)
                        }
                        .progressViewStyle(.linear)
                        .tint(count >= 45 ? .red : (count >= 30 ? .yellow : .green))

                        LabeledContent("Lifetime Usage") {
                            Text("\(user.total_fetches ?? 0) total lifetime fetches")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }

                // MARK: Admin Actions (not on own account)
                if !isSelf {
                    Section(header: Text("Super Admin Actions")) {
                        // Reset Quota — shows confirmation before executing
                        Button {
                            schedule(
                                title: "Reset Daily Quota",
                                message: "Reset \(user.email ?? "this user")'s daily fetch count back to 0?",
                                destructive: false
                            ) {
                                Task {
                                    await supabaseService.resetUserLimits(userId: user.id)
                                    onActionComplete()
                                    dismiss()
                                }
                            }
                        } label: {
                            Label("Reset Daily Quota", systemImage: "arrow.counterclockwise")
                                .foregroundStyle(.primary)
                        }

                        // Ban / Unban — shows confirmation before executing
                        Button {
                            let currentlyBanned = user.is_banned == true
                            schedule(
                                title: currentlyBanned ? "Unban User" : "Ban User",
                                message: currentlyBanned
                                    ? "Restore access for \(user.email ?? "this user")?"
                                    : "Block \(user.email ?? "this user") from accessing the app? This takes effect immediately.",
                                destructive: !currentlyBanned
                            ) {
                                Task {
                                    await supabaseService.syncToggleBan(userId: user.id, isBanned: !currentlyBanned)
                                    onActionComplete()
                                    dismiss()
                                }
                            }
                        } label: {
                            Label(
                                user.is_banned == true ? "Unban User" : "Ban User",
                                systemImage: user.is_banned == true ? "lock.open.fill" : "nosign"
                            )
                            .foregroundStyle(user.is_banned == true ? .green : .red)
                        }
                    }
                }
            }
            .navigationTitle("Manage User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            // Single unified confirmation alert for all admin actions
            .alert(confirmTitle, isPresented: $isShowingConfirmAlert) {
                Button("Cancel", role: .cancel) { confirmationAction = nil }
                Button("Continue", role: confirmIsDestructive ? .destructive : .none) {
                    confirmationAction?()
                    confirmationAction = nil
                }
            } message: {
                Text(confirmMessage)
            }
        }
    }
}

// MARK: - User Activity Detail View (super_admin only)

struct UserActivityDetailView: View {
    @EnvironmentObject private var supabaseService: SupabaseService
    @State private var adminUsers: [AdminUserStatus] = []
    @State private var isLoading: Bool = false
    @State private var selectedUser: AdminUserStatus? = nil

    var body: some View {
        List {
            if isLoading && adminUsers.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                Section {
                    ForEach(adminUsers) { user in
                        Button {
                            selectedUser = user
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(user.email ?? "Unknown")
                                        .font(.headline)
                                        .strikethrough(user.is_banned == true, color: .red)
                                        .foregroundStyle(.primary)
                                    if user.role == "super_admin" {
                                        Text("Role: Super Admin")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        let count = user.scrape_count_today ?? 0
                                        Text("Daily: \(count) / 50  ·  Lifetime: \(user.total_fetches ?? 0)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if user.is_banned == true {
                                    Text("BANNED")
                                        .font(.caption.bold())
                                        .foregroundStyle(.red)
                                } else if user.role == "super_admin" {
                                    Text(user.displayTime)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        let count = user.scrape_count_today ?? 0
                                        ProgressView(value: Double(count), total: 50.0)
                                            .progressViewStyle(.linear)
                                            .tint(count >= 45 ? .red : count >= 30 ? .yellow : .green)
                                            .frame(width: 64)
                                        Text(user.displayTime)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } footer: {
                    if !adminUsers.isEmpty {
                        Text("\(adminUsers.count) registered user(s)")
                    }
                }
            }
        }
        .navigationTitle("User Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await fetch() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .sheet(item: $selectedUser) { user in
            AdminUserDetailSheet(user: user, supabaseService: supabaseService, currentUserID: supabase.auth.currentUser?.id) {
                Task { await fetch() }
            }
        }
        .task { await fetch() }
    }

    private func fetch() async {
        isLoading = true
        do {
            // Explicit column list forces the RPC result set to include total_fetches
            // and role even if the function pre-dates those columns.
            let users: [AdminUserStatus] = try await supabase
                .rpc("get_all_users_status")
                .select("id, email, last_active, is_banned, scrape_count_today, last_scrape_reset, total_fetches, role, app_version")
                .execute()
                .value
            await MainActor.run { adminUsers = users }
        } catch {
            print("🔴 RPC Error fetching users: \(error)")
        }
        await MainActor.run { isLoading = false }
    }
}

// MARK: - Settings View

struct HPDSettingsView: View {
    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager

    @AppStorage("userRole")            private var userRole: String = "user"
    @AppStorage("hpdManualURLEnabled") private var manualURLModeEnabled: Bool = false
    @AppStorage("hpdManualURLInput")   private var hpdManualURLInput: String = ""
    @AppStorage("hpdHadLastError")     private var hpdHadLastError: Bool = false
    @AppStorage("hpdRefreshTrigger")   private var refreshTrigger: Int = 0
    @AppStorage("hpdCachedURL")        private var hpdCachedURL: String = ""
    @AppStorage("openWebInSafari")     private var openWebInSafari: Bool = false

    @State private var showClearOdoAlert         = false
    @State private var showSignOutAlert          = false
    @State private var showHPDWeb: Bool          = false
    @State private var showTerms: Bool           = false
    @State private var showPaywall: Bool         = false
    @State private var showManageSubscriptions   = false
    @State private var isLoadingProfile: Bool    = false
    @State private var isDataSourceExpanded: Bool = false
    @State private var showQuotaSheet: Bool = false

    private let defaultURLString = "https://www.houstontx.gov/police/auto_dealers_detail/Vehicles_Scheduled_For_Auction.htm"

    private var userEmail: String? { supabase.auth.currentUser?.email }

    // MARK: - Usage Dashboard

    private var currentCount: Int { supabaseService.currentProfile?.scrape_count_today ?? 0 }

    private var currentTierKey: String {
        supabaseService.currentProfile?.plan_tier?.lowercased() ?? storeManager.activeSubscriptionTier.tierKey
    }

    private var currentTierDisplayName: String {
        currentTierKey.capitalized
    }

    private var dailyLimit: Int {
        if let remoteLimit = supabaseService.tierConfigs[currentTierKey]?.daily_fetch_limit {
            return remoteLimit
        }

        switch currentTierKey {
        case "silver":
            return 10
        case "gold":
            return 30
        case "platinum":
            return 200
        default:
            return 3
        }
    }

    private var progressTint: Color {
        guard dailyLimit > 0 else { return .green }
        let ratio = Double(currentCount) / Double(dailyLimit)
        if ratio >= 0.9 { return .red }
        if ratio >= 0.6 { return .yellow }
        return .green
    }

    /// Returns the time remaining until the next midnight in the America/Chicago timezone.
    /// This matches the server-side RPC reset boundary exactly, regardless of the device's local timezone.
    private func resetsInMessage(now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        guard let midnight = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return currentCount == 0 ? "🟢 Full quota available" : "Reset time unknown"
        }
        let remaining = midnight.timeIntervalSince(now)
        guard remaining > 0 else { return "🟢 Quota recently reset" }
        let hours = Int(remaining) / 3600
        let mins  = (Int(remaining) % 3600) / 60
        if hours == 0 { return "Resets in \(mins) min (CT)" }
        return "Resets in \(hours) hr \(mins) min (CT)"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // Welcome header
                if let email = userEmail, !email.isEmpty {
                    Section {
                        Text("Welcome, \(email)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Super admin: single NavigationLink → UserActivityDetailView
                if userRole == "super_admin" {
                    Section(header: Text("Consumption")) {
                        NavigationLink {
                            UserActivityDetailView()
                        } label: {
                            Label("User Activity", systemImage: "chart.bar.fill")
                                .foregroundStyle(.primary)
                        }
                    }
                }

                // Regular user: Subscription tier + Upgrade / Manage Plan
                if userRole != "super_admin" {
                    Section(header: Text("Subscription")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Current Plan")
                                    .font(.subheadline)
                                Text(storeManager.activeSubscriptionTier.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                if storeManager.activeSubscriptionTier != .none {
                                    Button("Manage") { showManageSubscriptions = true }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                                if storeManager.activeSubscriptionTier != .platinum {
                                    Button("Upgrade Plan") { showPaywall = true }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                // Regular user: Daily Fetch Quota inline
                if userRole != "super_admin" {
                    Section {
                        QuotaUsageView()
                            .environmentObject(supabaseService)
                            .environmentObject(storeManager)
                    }
                }

                // Super admin: Data Source collapsed DisclosureGroup
                if userRole == "super_admin" {
                    Section {
                        DisclosureGroup("Data Source Information", isExpanded: $isDataSourceExpanded) {
                            LabeledContent("Default URL", value: defaultURLString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)

                            Button { refreshTrigger += 1 } label: {
                                Label("Refresh Now", systemImage: "arrow.clockwise")
                            }

                            Toggle("Edit URL Manually", isOn: $manualURLModeEnabled)
                                .tint(.blue)

                            Button { showHPDWeb = true } label: {
                                Label("Open HPD Web", systemImage: "safari")
                            }
                        }
                    }

                    if manualURLModeEnabled || hpdHadLastError {
                        Section(
                            header: Text("Manual URL"),
                            footer: Text("Use only if the target page changed. You can revert to the default URL anytime.")
                        ) {
                            TextField("https://…", text: $hpdManualURLInput)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .autocorrectionDisabled(true)

                            HStack {
                                Button {
                                    refreshTrigger += 1
                                } label: {
                                    Label("Fetch", systemImage: "arrow.down.circle")
                                }
                                .disabled(hpdManualURLInput.trimmingCharacters(in: .whitespaces).isEmpty)

                                Spacer()

                                Button {
                                    hpdManualURLInput = defaultURLString
                                    manualURLModeEnabled = false
                                    hpdHadLastError = false
                                } label: {
                                    Label("Use Default URL", systemImage: "arrow.uturn.backward")
                                }
                            }
                        }
                    }
                }

                // Browser Preferences
                Section(header: Text("Browser Preferences")) {
                    Toggle("Force External Safari for Reports", isOn: $openWebInSafari)
                }

                // Legal
                Section(header: Text("Legal")) {
                    Button("Terms & Conditions") {
                        showTerms = true
                    }
                    .foregroundStyle(.primary)
                }

                // Cache
                Section(
                    header: Text("Browser & Network Cache"),
                    footer: Text("Clears URLSession responses, WKWebView data (cookies, storage), and temp files. Your saved odometer readings, SPV values, and favorites are not affected.")
                ) {
                    Button(role: .destructive) {
                        showClearOdoAlert = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                }
                .alert("Clear Browser Cache", isPresented: $showClearOdoAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear", role: .destructive) {
                        supabaseService.clearAppCache()
                        refreshTrigger += 1   // trigger a fresh HPD data fetch
                    }
                } message: {
                    Text("This clears network responses and WKWebView data used by the scraping engine. Your saved odometer readings, SPV values, and favorites will not be deleted.")
                }

                // Sign Out
                Section {
                    Button(role: .destructive) {
                        showSignOutAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                            Spacer()
                        }
                    }
                }
                .alert("Sign Out", isPresented: $showSignOutAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Sign Out", role: .destructive) {
                        supabaseService.clearAllLocalState()
                        Task { try? await supabase.auth.signOut() }
                    }
                } message: {
                    Text("Are you sure you want to sign out?")
                }

                // App Version Footer
                Section {
                } footer: {
                    HStack {
                        Spacer()
                        Text("Bubick Company LLC v\(Bundle.main.appVersion)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showQuotaSheet = true
                    } label: {
                        if UIImage(named: currentTierKey) != nil {
                            Image(currentTierKey)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                        } else {
                            Image(systemName: "star.shield.fill")
                                .font(.title2)
                        }
                    }
                }
            }
            .sheet(isPresented: $showQuotaSheet) {
                QuotaUsageView()
                    .environmentObject(supabaseService)
                    .environmentObject(storeManager)
                    .presentationDetents([.height(300), .medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showHPDWeb) {
                NavigationStack {
                    if let url = URL(string: hpdCachedURL.isEmpty ? defaultURLString : hpdCachedURL) {
                        SafariView(url: url).ignoresSafeArea()
                    } else {
                        Text("Invalid URL")
                    }
                }
            }
            .sheet(isPresented: $showTerms) {
                LegalTermsView()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .onChange(of: storeManager.purchasedSubscriptions) { _, _ in
                        Task { await supabaseService.fetchCurrentProfile() }
                    }
            }
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
            .onAppear {
                if hpdManualURLInput.isEmpty {
                    hpdManualURLInput = defaultURLString
                }
            }
            .task {
                // Refresh tier configs on every Settings open — limits reflect DB without restart
                await supabaseService.fetchTierConfigs()
                guard userRole != "super_admin" else { return }
                isLoadingProfile = true
                await supabaseService.fetchCurrentProfile()
                isLoadingProfile = false
            }
        }
    }
}
