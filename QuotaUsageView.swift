import SwiftUI

struct QuotaUsageView: View {
    @EnvironmentObject private var supabaseService: SupabaseService
    @EnvironmentObject private var storeManager: StoreManager
    @AppStorage("userRole") private var userRole: String = "user"

    @State private var isLoadingProfile: Bool = false

    private var currentCount: Int {
        supabaseService.currentProfile?.effectiveScrapeCount ?? 0
    }

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

    private func resetsInMessage(now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        guard let midnight = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return currentCount == 0 ? "Full quota available" : "Reset time unknown"
        }
        let remaining = midnight.timeIntervalSince(now)
        guard remaining > 0 else { return "Quota recently reset" }
        let hours = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        if hours == 0 { return "Resets in \(mins) min (CT)" }
        return "Resets in \(hours) hr \(mins) min (CT)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily Fetch Quota")
                .font(.headline)

            if userRole == "super_admin" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current plan: \(currentTierDisplayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Unlimited quota")
                        .font(.subheadline.weight(.semibold))
                }
            } else if isLoadingProfile {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressView(
                            value: Double(currentCount),
                            total: Double(dailyLimit)
                        ) {
                            Text("Successful fetches today")
                                .font(.subheadline)
                        } currentValueLabel: {
                            Text("\(currentCount) of \(dailyLimit)")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .task {
            if supabaseService.currentProfile == nil {
                isLoadingProfile = true
                await supabaseService.fetchCurrentProfile()
                isLoadingProfile = false
            }
        }
    }
}
