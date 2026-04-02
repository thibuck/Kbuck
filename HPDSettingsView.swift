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
    var plan_tier: String?
    var app_version: String?

    var effectiveDailyUsage: Int {
        let rawCount = scrape_count_today ?? 0
        guard let raw = last_scrape_reset else { return rawCount }

        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        var resetDate: Date?

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        resetDate = isoFull.date(from: normalized)

        if resetDate == nil {
            let isoBasic = ISO8601DateFormatter()
            isoBasic.formatOptions = [.withInternetDateTime]
            resetDate = isoBasic.date(from: normalized)
        }

        if resetDate == nil {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
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

        guard let resetDate else { return rawCount }
        guard let centralTimeZone = TimeZone(identifier: "America/Chicago") else { return rawCount }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = centralTimeZone
        let todayStart = cal.startOfDay(for: Date())
        let resetStart = cal.startOfDay(for: resetDate)
        return resetStart < todayStart ? 0 : rawCount
    }

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
    let dailyLimit: Int?
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
                        let count = user.effectiveDailyUsage
                        if let dailyLimit, dailyLimit > 0 {
                            ProgressView(value: Double(count), total: Double(dailyLimit)) {
                                Text("Daily Usage: \(count) / \(dailyLimit) today")
                                    .font(.subheadline)
                            }
                            .progressViewStyle(.linear)
                            .tint(Double(count) / Double(dailyLimit) >= 0.9 ? .red : (Double(count) / Double(dailyLimit) >= 0.6 ? .yellow : .green))
                        } else {
                            Text("Daily Usage: \(count) today")
                                .font(.subheadline)
                        }

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
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var supabaseService: SupabaseService
    @State private var adminUsers: [AdminUserStatus] = []
    @State private var tierDailyLimits: [String: Int] = [:]
    @State private var isLoading: Bool = false
    @State private var expandedActionUserIDs: Set<UUID> = []
    @State private var isShowingConfirmAlert = false
    @State private var confirmTitle = ""
    @State private var confirmMessage = ""
    @State private var confirmIsDestructive = true
    @State private var confirmationAction: (() -> Void)? = nil

    private var activeUserCount: Int {
        adminUsers.filter { $0.is_banned != true }.count
    }

    private var bannedUserCount: Int {
        adminUsers.filter { $0.is_banned == true }.count
    }

    private var currentUserID: UUID? {
        supabase.auth.currentUser?.id
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                adminHeroCard

                if isLoading && adminUsers.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading users...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(28)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(adminUsers) { user in
                            userCard(for: user)
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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
        .alert(confirmTitle, isPresented: $isShowingConfirmAlert) {
            Button("Cancel", role: .cancel) { confirmationAction = nil }
            Button("Continue", role: confirmIsDestructive ? .destructive : .none) {
                confirmationAction?()
                confirmationAction = nil
            }
        } message: {
            Text(confirmMessage)
        }
        .task { await fetch() }
    }

    private func actionExpansionBinding(for userID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedActionUserIDs.contains(userID) },
            set: { isExpanded in
                if isExpanded {
                    expandedActionUserIDs.insert(userID)
                } else {
                    expandedActionUserIDs.remove(userID)
                }
            }
        )
    }

    private func schedule(title: String, message: String, destructive: Bool = true, action: @escaping () -> Void) {
        confirmTitle = title
        confirmMessage = message
        confirmIsDestructive = destructive
        confirmationAction = action
        isShowingConfirmAlert = true
    }

    private var adminHeroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HPD AUCTION")
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.74))
                    Text("User Activity")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Monitor usage, bans, plans, and app versions in one place.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.84))
                }
                Spacer()
                Image(systemName: "person.3.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack(spacing: 10) {
                AdminMetricPill(title: "Users", value: "\(adminUsers.count)")
                AdminMetricPill(title: "Active", value: "\(activeUserCount)")
                AdminMetricPill(title: "Banned", value: "\(bannedUserCount)")
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.33, blue: 0.62),
                    Color.black.opacity(colorScheme == .dark ? 0.45 : 0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func userCard(for user: AdminUserStatus) -> some View {
        let count = user.effectiveDailyUsage
        let limit = dailyLimit(for: user)
        let ratio = usageRatio(count: count, limit: limit)
        let tierName = normalizedTierName(for: user)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .frame(width: 48, height: 48)
                    if isTierLoading(for: user) {
                        ProgressView()
                            .controlSize(.small)
                    } else if let tierName, UIImage(named: tierName) != nil {
                        Image(tierName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: user.role == "super_admin" ? "crown.fill" : "person.fill")
                            .foregroundStyle(user.role == "super_admin" ? .yellow : .secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(user.email ?? "Unknown")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if user.is_banned == true {
                            Text("BANNED")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.red.opacity(0.14))
                                .foregroundStyle(.red)
                                .clipShape(Capsule())
                        }
                    }

                    Text(user.role == "super_admin" ? "Super Admin" : "Plan: \((tierName ?? "free").capitalized)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Last active: \(user.displayTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if user.role != "super_admin" {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Daily Usage")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if limit > 0 {
                            Text("\(count) / \(limit)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(uiColor: .tertiarySystemFill))
                            Capsule()
                                .fill(progressTint(count: count, limit: limit))
                                .frame(width: max(12, proxy.size.width * ratio))
                        }
                    }
                    .frame(height: 8)
                }
            }

            HStack(spacing: 10) {
                activityInfoChip(title: "Lifetime", value: "\(user.total_fetches ?? 0)")
                activityInfoChip(title: "Version", value: "v\(user.app_version ?? "N/A")")
                if user.role != "super_admin" {
                    activityInfoChip(title: "Today", value: "\(count)")
                }
            }

            if user.id != currentUserID {
                DisclosureGroup("Admin Actions", isExpanded: actionExpansionBinding(for: user.id)) {
                    VStack(spacing: 10) {
                        Button {
                            schedule(
                                title: "Reset Daily Quota",
                                message: "Reset \(user.email ?? "this user")'s daily fetch count back to 0?",
                                destructive: false
                            ) {
                                Task {
                                    await supabaseService.resetUserLimits(userId: user.id)
                                    await fetch()
                                }
                            }
                        } label: {
                            adminActionRow(
                                title: "Reset Daily Fetch",
                                subtitle: "Set today's usage back to zero",
                                systemImage: "arrow.counterclockwise",
                                tint: .blue
                            )
                        }
                        .buttonStyle(.plain)

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
                                    await fetch()
                                }
                            }
                        } label: {
                            adminActionRow(
                                title: user.is_banned == true ? "Unban User" : "Ban User",
                                subtitle: user.is_banned == true ? "Restore access immediately" : "Disable access immediately",
                                systemImage: user.is_banned == true ? "lock.open.fill" : "nosign",
                                tint: user.is_banned == true ? .green : .red
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .font(.subheadline.weight(.semibold))
                .tint(.primary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 1)
        )
    }

    private func activityInfoChip(title: String, value: String) -> some View {
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
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func adminActionRow(title: String, subtitle: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func fetch() async {
        isLoading = true
        do {
            // Explicit column list forces the RPC result set to include total_fetches,
            // role, plan_tier and app_version.
            let response = try await supabase
                .rpc("get_all_users_status")
                .select("id, email, last_active, is_banned, scrape_count_today, last_scrape_reset, total_fetches, role, plan_tier, app_version")
                .execute()

            let decoder = JSONDecoder()
            do {
                let users = try decoder.decode([AdminUserStatus].self, from: response.data)
                for user in users {
                    logAdminUserDiagnostics(user)
                }
                let limits = await fetchTierDailyLimits()
                await MainActor.run {
                    tierDailyLimits = limits
                    adminUsers = users
                }
            } catch let error as DecodingError {
                print("Decoding Error: \(error)")

                if let payload = try? JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] {
                    var recoveredUsers: [AdminUserStatus] = []
                    for row in payload {
                        do {
                            let rowData = try JSONSerialization.data(withJSONObject: row)
                            let user = try decoder.decode(AdminUserStatus.self, from: rowData)
                            logAdminUserDiagnostics(user)
                            recoveredUsers.append(user)
                        } catch let rowError as DecodingError {
                            print("Decoding Error: \(rowError)")
                        } catch {
                            print("🔴 Row decode error: \(error)")
                        }
                    }
                    let limits = await fetchTierDailyLimits()
                    await MainActor.run {
                        tierDailyLimits = limits
                        adminUsers = recoveredUsers
                    }
                }
            }
        } catch {
            print("🔴 RPC Error fetching users: \(error)")
        }
        await MainActor.run { isLoading = false }
    }

    private func normalizedTierName(for user: AdminUserStatus) -> String? {
        guard let tier = user.plan_tier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty else { return nil }
        return tier.lowercased()
    }

    private func isTierLoading(for user: AdminUserStatus) -> Bool {
        guard let rawTier = user.plan_tier else { return true }
        let normalized = rawTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "loading"
    }

    private func dailyLimit(for user: AdminUserStatus) -> Int {
        guard let tierKey = normalizedTierName(for: user) else { return 0 }
        return tierDailyLimits[tierKey] ?? 0
    }

    private func progressTint(count: Int, limit: Int) -> Color {
        guard limit > 0 else { return .green }
        let ratio = Double(count) / Double(limit)
        if ratio >= 0.9 { return .red }
        if ratio >= 0.6 { return .yellow }
        return .green
    }

    private func usageRatio(count: Int, limit: Int) -> CGFloat {
        guard limit > 0 else { return 0.12 }
        return min(max(CGFloat(Double(count) / Double(limit)), 0.12), 1.0)
    }

    private func fetchTierDailyLimits() async -> [String: Int] {
        struct TierLimitRow: Decodable {
            let tier_name: String
            let daily_fetch_limit: Int
        }

        do {
            let rows: [TierLimitRow] = try await supabase
                .from("subscription_tiers_kbuck")
                .select("tier_name, daily_fetch_limit")
                .execute()
                .value

            return Dictionary(uniqueKeysWithValues: rows.map { ($0.tier_name.lowercased(), $0.daily_fetch_limit) })
        } catch {
            print("🔴 Failed to fetch tier daily limits: \(error)")
            return [:]
        }
    }

    private func logAdminUserDiagnostics(_ user: AdminUserStatus) {
        let email = user.email ?? "Unknown"
        let tier = user.plan_tier
        let totalFetches = user.total_fetches ?? 0
        let appVersion = user.app_version
        print("DEBUG USER ADMIN: Fetched profile for \(email)")
        print("DEBUG USER ADMIN: -> Tier: \(tier ?? "NIL")")
        print("DEBUG USER ADMIN: -> Lifetime Fetches: \(totalFetches)")
        print("DEBUG USER ADMIN: -> App Version: \(appVersion ?? "NIL")")
    }
}

// MARK: - Settings View

struct HPDSettingsView: View {
    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager
    @Environment(\.colorScheme) private var colorScheme

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
    private let defaultURLString = "https://www.houstontx.gov/police/auto_dealers_detail/Vehicles_Scheduled_For_Auction.htm"

    private var userEmail: String? { supabase.auth.currentUser?.email }

    // MARK: - Usage Dashboard

    private var currentCount: Int { supabaseService.currentProfile?.effectiveDailyUsage ?? 0 }

    private var currentTierKey: String {
        supabaseService.currentProfile?.plan_tier?.lowercased() ?? storeManager.activeSubscriptionTier.tierKey
    }

    private var currentTierDisplayName: String {
        currentTierKey.capitalized
    }

    private var currentProfileTierDisplay: String? {
        guard let tier = supabaseService.currentTier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty else { return nil }
        return tier.capitalized
    }

    private var settingsPlanLabel: String {
        currentProfileTierDisplay ?? currentTierDisplayName
    }

    private var nextRenewalPlanLabel: String? {
        guard let nextTier = storeManager.nextRenewalTier, nextTier != .none else { return nil }
        return nextTier.displayName
    }

    private var heroBackgroundColors: [Color] {
        if colorScheme == .dark {
            return [
                tierAccent.opacity(0.6),
                Color(uiColor: .secondarySystemBackground)
            ]
        }
        return [
            tierAccent.opacity(0.95),
            Color.black.opacity(0.78)
        ]
    }

    private var heroPrimaryTextColor: Color {
        colorScheme == .dark ? .primary : .white
    }

    private var heroSecondaryTextColor: Color {
        colorScheme == .dark ? .secondary : .white.opacity(0.82)
    }

    private var heroMutedTextColor: Color {
        colorScheme == .dark ? .secondary.opacity(0.9) : .white.opacity(0.78)
    }

    private var heroChipBackground: Color {
        colorScheme == .dark ? Color(uiColor: .tertiarySystemFill) : .white.opacity(0.12)
    }

    private var heroSecondaryButtonBackground: Color {
        colorScheme == .dark ? Color(uiColor: .tertiarySystemFill) : .white.opacity(0.12)
    }

    private var tierAccent: Color {
        switch currentTierKey {
        case "platinum":
            return Color(red: 0.78, green: 0.66, blue: 0.33)
        case "gold":
            return Color(red: 0.84, green: 0.61, blue: 0.18)
        case "silver":
            return Color(red: 0.49, green: 0.56, blue: 0.66)
        default:
            return Color.blue
        }
    }

    private var tierIconName: String {
        if userRole == "super_admin" { return "crown.fill" }
        switch currentTierKey {
        case "platinum": return "sparkles"
        case "gold": return "medal.fill"
        case "silver": return "shield.lefthalf.filled"
        default: return "bolt.fill"
        }
    }

    private var hasTierAsset: Bool {
        UIImage(named: currentTierKey) != nil
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
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(colorScheme == .dark ? Color(uiColor: .tertiarySystemFill) : .white.opacity(0.16))
                                    .frame(width: 54, height: 54)
                                if hasTierAsset {
                                    Image(currentTierKey)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 34, height: 34)
                                } else {
                                    Image(systemName: tierIconName)
                                        .font(.title2.weight(.semibold))
                                        .foregroundStyle(heroPrimaryTextColor)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("HPD AUCTION")
                                    .font(.caption.weight(.semibold))
                                    .tracking(1.2)
                                    .foregroundStyle(heroMutedTextColor)
                                Text("Settings")
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(heroPrimaryTextColor)
                                Text(userEmail ?? "Account")
                                    .font(.subheadline)
                                    .foregroundStyle(heroSecondaryTextColor)
                                    .lineLimit(1)
                                if let nextRenewalPlanLabel {
                                    Text("Next Renewal: \(nextRenewalPlanLabel)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(heroMutedTextColor)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 10) {
                            SettingsMetricChip(
                                title: "Plan",
                                value: isLoadingProfile && currentProfileTierDisplay == nil ? "Loading..." : settingsPlanLabel,
                                tint: heroPrimaryTextColor,
                                titleTint: heroMutedTextColor,
                                backgroundTint: heroChipBackground
                            )

                            SettingsMetricChip(
                                title: userRole == "super_admin" ? "Access" : "Usage",
                                value: userRole == "super_admin" ? "Unlimited" : "\(currentCount) / \(dailyLimit)",
                                tint: userRole == "super_admin" ? heroPrimaryTextColor : progressTint,
                                titleTint: heroMutedTextColor,
                                backgroundTint: heroChipBackground
                            )
                        }

                        Text(userRole == "super_admin" ? "Super Admin Access" : resetsInMessage(now: Date()))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(heroSecondaryTextColor)

                        if userRole != "super_admin" {
                            HStack(spacing: 10) {
                                if storeManager.activeSubscriptionTier != .none {
                                    Button {
                                        showManageSubscriptions = true
                                    } label: {
                                        Text("Manage")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(heroPrimaryTextColor)
                                    .background(heroSecondaryButtonBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }

                                if storeManager.activeSubscriptionTier != .platinum {
                                    Button {
                                        showPaywall = true
                                    } label: {
                                        Text("Upgrade")
                                            .font(.subheadline.weight(.bold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(colorScheme == .dark ? .white : .black)
                                    .background(colorScheme == .dark ? tierAccent.opacity(0.8) : Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                            }
                        }
                    }
                    .padding(18)
                    .background(
                        LinearGradient(
                            colors: heroBackgroundColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                    .listRowBackground(Color.clear)
                }

                if userRole != "super_admin" {
                    Section(
                        header: Text("Usage Details"),
                        footer: Text("Every successful hammer extraction consumes quota, including results loaded instantly from Supabase cache.")
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Your current quota snapshot is shown in the header card above.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Button {
                                Task {
                                    isLoadingProfile = true
                                    await supabaseService.fetchTierConfigs()
                                    await supabaseService.fetchCurrentProfile()
                                    isLoadingProfile = false
                                }
                            } label: {
                                Label("Refresh Usage", systemImage: "arrow.clockwise")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if userRole == "super_admin" {
                    Section(header: Text("Admin Tools")) {
                        NavigationLink {
                            UserActivityDetailView()
                        } label: {
                            Label("User Activity", systemImage: "chart.bar.fill")
                        }

                        DisclosureGroup("Data Source Controls", isExpanded: $isDataSourceExpanded) {
                            LabeledContent("Default URL", value: defaultURLString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)

                            Toggle("Enable Manual URL", isOn: $manualURLModeEnabled)
                                .tint(.blue)

                            Button {
                                refreshTrigger += 1
                            } label: {
                                Label("Refresh HPD Data", systemImage: "arrow.clockwise")
                            }

                            Button {
                                showHPDWeb = true
                            } label: {
                                Label("Open HPD Source", systemImage: "safari")
                            }
                        }
                    }

                    if manualURLModeEnabled || hpdHadLastError {
                        Section(
                            header: Text("Manual Source URL"),
                            footer: Text("Use this only when the HPD page changes structure or the default link breaks.")
                        ) {
                            TextField("https://…", text: $hpdManualURLInput)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .autocorrectionDisabled(true)

                            Button {
                                refreshTrigger += 1
                            } label: {
                                Label("Fetch From Custom URL", systemImage: "arrow.down.circle")
                            }
                            .disabled(hpdManualURLInput.trimmingCharacters(in: .whitespaces).isEmpty)

                            Button {
                                hpdManualURLInput = defaultURLString
                                manualURLModeEnabled = false
                                hpdHadLastError = false
                            } label: {
                                Label("Restore Default URL", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                }

                Section(header: Text("Preferences")) {
                    Toggle("Open Reports in Safari", isOn: $openWebInSafari)
                }

                Section(
                    header: Text("Cache & Browser"),
                    footer: Text("Clears URLSession responses, WKWebView data, cookies, storage, and temp files. Favorites and saved quick data stay intact.")
                ) {
                    Button(role: .destructive) {
                        showClearOdoAlert = true
                    } label: {
                        Label("Clear Browser Cache", systemImage: "trash")
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

                Section(header: Text("Legal & Support")) {
                    Button("Terms & Conditions") {
                        showTerms = true
                    }
                    .foregroundStyle(.primary)
                }

                Section(header: Text("Account")) {
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
            .scrollContentBackground(.hidden)
            .background(
                Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
            )
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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
            .onChange(of: storeManager.purchasedSubscriptions) { _, _ in
                if showManageSubscriptions {
                    showManageSubscriptions = false
                }
                Task {
                    await supabaseService.fetchTierConfigs()
                    await supabaseService.fetchCurrentProfile()
                }
            }
            .onChange(of: showManageSubscriptions) { _, isPresented in
                guard !isPresented else { return }
                Task {
                    await storeManager.updateCustomerProductStatus()
                    await supabaseService.fetchTierConfigs()
                    await supabaseService.fetchCurrentProfile()
                }
            }
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

private struct SettingsMetricChip: View {
    let title: String
    let value: String
    let tint: Color
    let titleTint: Color
    let backgroundTint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(titleTint)
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(backgroundTint)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AdminMetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
