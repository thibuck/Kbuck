import SwiftUI
import StoreKit

// MARK: - Tier Feature Data Source

/// Maps a StoreKit product ID to the `tier_name` key used in `subscription_tiers_kbuck`.
private func tierKey(for productId: String) -> String {
    switch productId {
    case "com.kbuck.silver.monthly":   return "silver"
    case "com.kbuck.gold.monthly":     return "gold"
    case "com.kbuck.platinum.monthly": return "platinum"
    default:                            return "free"
    }
}

/// Builds the feature bullet list for a given product/tier.
/// Reads DB integers strictly — only renders "Unlimited" when the stored value is >= 999999.
private func features(for tierId: String, configs: [String: TierConfig]) -> [String] {
    let key = tierKey(for: tierId)
    let cfg = configs[key]

    func extractionStr(_ n: Int) -> String {
        n >= 999999 ? "Unlimited daily HPD extractions" : "\(n) daily HPD extractions"
    }
    func favoritesStr(_ n: Int) -> String {
        n >= 999999 ? "Unlimited favorites" : "Save up to \(n) favorites"
    }

    switch tierId {
    case "free":
        let fetches = cfg.map { extractionStr($0.daily_fetch_limit) } ?? "3 daily HPD extractions"
        let favs    = cfg.map { favoritesStr($0.max_favorites) }       ?? "Save up to 3 favorites"
        return [fetches, favs, "Basic auction access"]

    case "com.kbuck.silver.monthly":
        let fetches = cfg.map { extractionStr($0.daily_fetch_limit) } ?? "10 daily HPD extractions"
        let favs    = cfg.map { favoritesStr($0.max_favorites) }       ?? "Save up to 10 favorites"
        return [fetches, favs, "Standard push notifications"]

    case "com.kbuck.gold.monthly":
        let fetches = cfg.map { extractionStr($0.daily_fetch_limit) } ?? "30 daily HPD extractions"
        let favs    = cfg.map { favoritesStr($0.max_favorites) }       ?? "Save up to 30 favorites"
        return [fetches, favs, "Priority real-time notifications", "Quick Inventory Access"]

    case "com.kbuck.platinum.monthly":
        let fetches = cfg.map { extractionStr($0.daily_fetch_limit) } ?? "200 daily HPD extractions"
        let favs    = cfg.map { favoritesStr($0.max_favorites) }       ?? "Unlimited favorites"
        return [fetches, favs, "Discounted Carfax reports", "Dedicated dealer dashboard"]

    default:
        return []
    }
}

// MARK: - Paywall View

struct PaywallView: View {

    @EnvironmentObject private var storeManager: StoreManager
    @EnvironmentObject private var supabaseService: SupabaseService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProduct: Product? = nil
    @State private var isPurchasing: Bool = false
    @State private var purchaseError: String? = nil

    private var isOnFreeTier: Bool { storeManager.activeSubscriptionTier == .none }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection

                    if storeManager.isLoading {
                        ProgressView("Loading plans…")
                            .padding(.top, 40)
                    } else {
                        plansSection
                    }

                    purchaseButton
                    legalSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Not Now") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
            // Refresh tier config each time the sheet opens — no restart needed
            .task { await supabaseService.fetchTierConfigs() }
            // Auto-dismiss when a subscription activates
            .onChange(of: storeManager.purchasedSubscriptions) { _, newValue in
                if !newValue.isEmpty { dismiss() }
            }
            .alert("Purchase Error", isPresented: Binding(
                get: { purchaseError != nil },
                set: { if !$0 { purchaseError = nil } }
            )) {
                Button("OK", role: .cancel) { purchaseError = nil }
            } message: {
                Text(purchaseError ?? "")
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "car.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
                .padding(.top, 24)

            Text("Unlock HPD Auction Data")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Current Plan: \(storeManager.activeSubscriptionTier.displayName)")
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(isOnFreeTier ? Color(.systemGray5) : Color.blue.opacity(0.15))
                .foregroundStyle(isOnFreeTier ? Color.secondary : Color.blue)
                .clipShape(Capsule())

            Text("Get real-time access to HPD auction listings, VIN history lookups, and instant deal alerts — all in one place.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Plans Section

    private var plansSection: some View {
        let configs = supabaseService.tierConfigs
        return VStack(spacing: 12) {

            // Free tier baseline card — always shown at top for price anchoring
            FreeTierCard(
                isCurrentPlan: isOnFreeTier,
                features: features(for: "free", configs: configs)
            )

            // Paid tiers from StoreKit, sorted by price (Silver → Gold → Platinum)
            if storeManager.subscriptions.isEmpty {
                if let error = storeManager.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.subheadline.bold())
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    Text("No plans available at this moment.")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(storeManager.subscriptions, id: \.id) { product in
                    PaidPlanCard(
                        product: product,
                        features: features(for: product.id, configs: configs),
                        isSelected: selectedProduct?.id == product.id
                    )
                    .onTapGesture { selectedProduct = product }
                }
            }
        }
        .onAppear {
            if selectedProduct == nil {
                selectedProduct = storeManager.subscriptions.first(where: {
                    $0.id == "com.kbuck.gold.monthly"
                }) ?? storeManager.subscriptions.first
            }
        }
    }

    // MARK: - Purchase Button

    private var purchaseButton: some View {
        VStack(spacing: 10) {
            Button {
                guard let product = selectedProduct else { return }
                isPurchasing = true
                Task {
                    defer { isPurchasing = false }
                    do {
                        let success = try await storeManager.purchase(product)
                        if success {
                            await MainActor.run {
                                dismiss()
                            }
                        }
                    } catch StoreManager.PurchaseError.pending {
                        purchaseError = "Your purchase is pending approval."
                    } catch StoreManager.PurchaseError.verificationFailed {
                        purchaseError = "Purchase verification failed. Please contact support."
                    } catch {
                        purchaseError = error.localizedDescription
                    }
                }
            } label: {
                Group {
                    if isPurchasing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(selectedProduct.map { "Subscribe for \($0.displayPrice)/mo" } ?? "Select a Plan")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(selectedProduct == nil || isPurchasing)

            Text("Cancel anytime. Billed monthly. No hidden fees.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Legal Footer (App Store Review Guideline 3.1.1 — MANDATORY)

    private var legalSection: some View {
        VStack(spacing: 16) {
            Divider()

            Button {
                Task { try? await AppStore.sync() }
            } label: {
                Text("Restore Purchases")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }

            HStack(spacing: 24) {
                Link("Terms of Use", destination: URL(string: "https://example.com/terms")!)
                Link("Privacy Policy", destination: URL(string: "https://example.com/privacy")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Subscriptions automatically renew unless canceled at least 24 hours before the end of the current period. Manage or cancel in your Apple ID Account Settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Free Tier Card

private struct FreeTierCard: View {
    let isCurrentPlan: Bool
    let features: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free")
                        .font(.headline)
                    Text("$0.00 / month")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Optional badge asset — silently skipped if not in Assets
                if let _ = UIImage(named: "badge_free") {
                    Image("badge_free")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "person.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ForEach(features, id: \.self) { feature in
                Label(feature, systemImage: "checkmark")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
            }

            // Action area
            if isCurrentPlan {
                Text("Current Plan")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray5))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isCurrentPlan ? Color.gray.opacity(0.4) : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Paid Plan Card

private struct PaidPlanCard: View {

    let product: Product
    let features: [String]
    let isSelected: Bool

    private var isRecommended: Bool { product.id == "com.kbuck.gold.monthly" }

    /// Explicit tier name — guards against empty displayName in local StoreKit config.
    private var tierName: String {
        switch product.id {
        case "com.kbuck.silver.monthly":   return "Silver"
        case "com.kbuck.gold.monthly":     return "Gold"
        case "com.kbuck.platinum.monthly": return "Platinum"
        default: return product.displayName.isEmpty ? product.id : product.displayName
        }
    }

    /// Asset name to attempt loading from the app's asset catalog.
    private var badgeAssetName: String { "badge_\(tierName.lowercased())" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(tierName)
                            .font(.headline)
                        if isRecommended {
                            Text("POPULAR")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(product.displayPrice) / month")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Optional tier badge — silently falls back to SF Symbol if asset is missing
                if UIImage(named: badgeAssetName) != nil {
                    Image(badgeAssetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                }
            }

            if !features.isEmpty {
                Divider()
                ForEach(features, id: \.self) { feature in
                    Label(feature, systemImage: "checkmark")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: isSelected ? .blue.opacity(0.25) : .black.opacity(0.06),
                    radius: isSelected ? 6 : 3,
                    y: 2
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Preview

#Preview {
    PaywallView()
        .environmentObject(StoreManager())
        .environmentObject(SupabaseService())
}
