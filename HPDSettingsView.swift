import SwiftUI
import Supabase

struct AdminUserStatus: Codable, Identifiable {
    let id: UUID
    let email: String?
    let last_active: String?
    let is_banned: Bool?
    let scrape_count_today: Int?
    let last_scrape_reset: String?
    
    var displayTime: String {
        guard let raw = last_active else { return "Never" }
        
        // Normalize PostgREST timestamptz (replace space with T)
        let cleanStr = raw.replacingOccurrences(of: " ", with: "T")
        var date: Date? = nil
        
        // 1. Try strict ISO8601 (often fails on 6-digit microseconds)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = isoFormatter.date(from: cleanStr)
        
        if date == nil {
            isoFormatter.formatOptions = [.withInternetDateTime]
            date = isoFormatter.date(from: cleanStr)
        }
        
        // 2. Fallback: Robust POSIX formatter for 6-digit microseconds (Supabase default)
        if date == nil {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0) // Force UTC interpretation
            
            let formats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            ]
            
            for format in formats {
                df.dateFormat = format
                if let parsed = df.date(from: cleanStr) {
                    date = parsed
                    break
                }
            }
        }
        
        guard let validDate = date else { return "Format Error" }
        
        let diff = Date().timeIntervalSince(validDate)
        
        // If difference is negative (clock skew) or under 5 minutes, user is Online
        if diff >= -60 && diff < 300 { 
            return "🟢 Online" 
        }
        
        let relFormatter = RelativeDateTimeFormatter()
        relFormatter.unitsStyle = .abbreviated
        return relFormatter.localizedString(for: validDate, relativeTo: Date())
    }
}

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
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Admin User Detail Sheet

struct AdminUserDetailSheet: View {
    let user: AdminUserStatus
    let supabaseService: SupabaseService
    let onActionComplete: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("User Identity")) {
                    LabeledContent("Email", value: user.email ?? "Unknown")
                    LabeledContent("Last Active", value: user.displayTime)
                    if user.is_banned == true {
                        Text("Account is currently BANNED")
                            .foregroundStyle(.red)
                            .font(.caption.bold())
                    }
                }

                Section(header: Text("Today's Quota Usage")) {
                    let count = user.scrape_count_today ?? 0
                    ProgressView(value: Double(count), total: 50.0) {
                        Text("\(count) of 50 Extractions Used")
                            .font(.subheadline)
                    }
                    .progressViewStyle(.linear)
                    .tint(count >= 45 ? .red : (count >= 30 ? .yellow : .green))
                }

                Section(header: Text("Super Admin Actions")) {
                    Button(role: .none) {
                        Task {
                            await supabaseService.resetUserLimits(userId: user.id)
                            onActionComplete()
                            dismiss()
                        }
                    } label: {
                        Label("Reset Daily Quota", systemImage: "arrow.counterclockwise")
                            .foregroundStyle(.blue)
                    }

                    Button(role: user.is_banned == true ? .none : .destructive) {
                        Task {
                            await supabaseService.syncToggleBan(userId: user.id, isBanned: !(user.is_banned == true))
                            onActionComplete()
                            dismiss()
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
            .navigationTitle("Manage User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

struct HPDSettingsView: View {
    @EnvironmentObject private var supabaseService: SupabaseService

    // Role written by ContentView after fetching from the profiles table.
    @AppStorage("userRole") private var userRole: String = "user"

    // Shared AppStorage keys read/written by HPDView as well
    @AppStorage("hpdManualURLEnabled") private var manualURLModeEnabled: Bool = false
    @AppStorage("hpdManualURLInput")   private var hpdManualURLInput: String = ""
    @AppStorage("hpdHadLastError")     private var hpdHadLastError: Bool = false
    @AppStorage("hpdRefreshTrigger")   private var refreshTrigger: Int = 0
    @AppStorage("hpdCachedURL")        private var hpdCachedURL: String = ""
    @AppStorage("openWebInSafari")     private var openWebInSafari: Bool = false

    // Local state
    @State private var showClearOdoAlert = false
    @State private var showSignOutAlert  = false
    @State private var showHPDWeb: Bool  = false
    @State private var showTerms: Bool   = false
    @State private var adminUsers: [AdminUserStatus] = []
    @State private var isLoadingUsers: Bool = false
    @State private var isLoadingProfile: Bool = false
    @State private var selectedAdminUser: AdminUserStatus? = nil
    @State private var isDataSourceExpanded: Bool = false

    private let defaultURLString = "https://www.houstontx.gov/police/auto_dealers_detail/Vehicles_Scheduled_For_Auction.htm"

    private var userEmail: String? { supabase.auth.currentUser?.email }

    // MARK: - Usage Dashboard Computed Properties

    private var currentCount: Int { supabaseService.currentProfile?.scrape_count_today ?? 0 }

    private var progressTint: Color {
        if currentCount >= 45 { return .red }
        if currentCount >= 30 { return .yellow }
        return .green
    }

    private var lastResetDate: Date? {
        guard let raw = supabaseService.currentProfile?.last_scrape_reset else { return nil }
        let clean = raw.replacingOccurrences(of: " ", with: "T")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: clean) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: clean) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ"] {
            df.dateFormat = fmt
            if let d = df.date(from: clean) { return d }
        }
        return nil
    }

    private func resetsInMessage(now: Date) -> String {
        guard let reset = lastResetDate else {
            return currentCount == 0 ? "🟢 Full quota available" : "Reset time unknown"
        }
        let nextReset = reset.addingTimeInterval(86400)
        let remaining = nextReset.timeIntervalSince(now)
        if remaining <= 0 { return "🟢 Quota recently reset" }
        let hours = Int(remaining) / 3600
        let mins  = (Int(remaining) % 3600) / 60
        if hours == 0 { return "Resets in \(mins) min" }
        return "Resets in \(hours) hr \(mins) min"
    }

    private func fetchAdminUsers() async {
        isLoadingUsers = true
        do {
            let users: [AdminUserStatus] = try await supabase.rpc("get_all_users_status").execute().value
            await MainActor.run { self.adminUsers = users }
        } catch {
            print("🔴 RPC Error fetching users: \(error)")
        }
        await MainActor.run { isLoadingUsers = false }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let email = userEmail, !email.isEmpty {
                    Section {
                        Text("Welcome, \(email)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                if userRole == "super_admin" {
                    Section(header: Text("User Activity")) {
                        if isLoadingUsers && adminUsers.isEmpty {
                            ProgressView()
                        } else {
                            ForEach(adminUsers) { user in
                                Button {
                                    selectedAdminUser = user
                                } label: {
                                    HStack {
                                        Text(user.email ?? "Unknown")
                                            .font(.subheadline)
                                            .strikethrough(user.is_banned == true, color: .red)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if user.is_banned == true {
                                            Text("BANNED").font(.caption.bold()).foregroundStyle(.red)
                                        } else {
                                            Text(user.displayTime)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        Button {
                            Task {
                                await fetchAdminUsers()
                                await supabaseService.fetchCurrentProfile()
                            }
                        } label: {
                            Label("Refresh Users", systemImage: "arrow.clockwise")
                        }
                    }
                }

                if userRole != "super_admin" {
                    Section(header: Text("DAILY FETCH QUOTA")) {
                        if isLoadingProfile {
                            ProgressView()
                        } else {
                            TimelineView(.everyMinute) { context in
                                VStack(alignment: .leading, spacing: 10) {
                                    ProgressView(
                                        value: Double(currentCount),
                                        total: 50.0
                                    ) {
                                        Text("Successful fetches today")
                                            .font(.subheadline)
                                    } currentValueLabel: {
                                        Text("\(currentCount) of 50")
                                            .font(.caption.monospacedDigit())
                                    }
                                    .progressViewStyle(.linear)
                                    .tint(progressTint)

                                    Text(resetsInMessage(now: context.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text("Failed extraction attempts do not consume quota slots. A unique extraction credit is deducted only upon successful data cache.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                Task {
                                    isLoadingProfile = true
                                    await supabaseService.fetchCurrentProfile()
                                    isLoadingProfile = false
                                }
                            } label: {
                                Label("Refresh Usage", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    .disabled(isLoadingProfile)
                }

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

                Section(header: Text("Browser Preferences")) {
                    Toggle("Force External Safari for Reports", isOn: $openWebInSafari)
                }

                Section(header: Text("Legal")) {
                    Button("Terms & Conditions") {
                        showTerms = true
                    }
                }

                Section(
                    header: Text("ODO / Date / SPV Cache"),
                    footer: Text("This only clears the locally saved odometer, date, and Private Value data.")
                ) {
                    Button(role: .destructive) {
                        showClearOdoAlert = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                }
                .alert("Clear Cache", isPresented: $showClearOdoAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear", role: .destructive) {
                        supabaseService.clearOdoCache()
                    }
                } message: {
                    Text("This will permanently delete saved odometers, dates, and SPV values. This action cannot be undone.")
                }

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
            }
            .navigationTitle("Settings")
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
            .sheet(item: $selectedAdminUser) { user in
                AdminUserDetailSheet(user: user, supabaseService: supabaseService) {
                    Task { await fetchAdminUsers() }
                }
            }
            .onAppear {
                // Pre-fill manual URL field with the default so the text field isn't blank
                if hpdManualURLInput.isEmpty {
                    hpdManualURLInput = defaultURLString
                }
            }
            .task {
                if userRole == "super_admin" {
                    await fetchAdminUsers()
                } else {
                    isLoadingProfile = true
                    await supabaseService.fetchCurrentProfile()
                    isLoadingProfile = false
                }
            }
        }
    }
}
