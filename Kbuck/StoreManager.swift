import Foundation
import StoreKit
import Combine
import Supabase

@MainActor
final class StoreManager: ObservableObject {

    // MARK: - Published State

    @Published var subscriptions: [Product] = []
    @Published var consumables: [Product] = []
    @Published var purchasedSubscriptions: [Product] = []
    @Published var carfaxCredits: Int = 0
    @Published var nextRenewalTier: SubscriptionTier? = nil
    @Published var nextRenewalDate: Date? = nil
    @Published var nextRenewalPrice: String? = nil
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    // MARK: - Product IDs

    static let subscriptionIDs: [String] = [
        "com.kbuck.silver.monthly",
        "com.kbuck.gold.monthly",
        "com.kbuck.platinum.monthly"
    ]

    static let consumableIDs: [String] = [
        "com.kbuck.carfax.standard",   // $15.99 — available to all tiers
        "com.kbuck.carfax.platinum"    // $10.99 — discounted rate for Platinum
    ]

    static let allProductIDs: [String] = subscriptionIDs + consumableIDs

    // MARK: - Active Subscription Tier

    var activeSubscriptionTier: SubscriptionTier {
        if purchasedSubscriptions.contains(where: { $0.id == "com.kbuck.platinum.monthly" }) {
            return .platinum
        } else if purchasedSubscriptions.contains(where: { $0.id == "com.kbuck.gold.monthly" }) {
            return .gold
        } else if purchasedSubscriptions.contains(where: { $0.id == "com.kbuck.silver.monthly" }) {
            return .silver
        }
        return .none
    }

    enum SubscriptionTier {
        case silver, gold, platinum, none

        var displayName: String {
            switch self {
            case .silver:   return "Silver"
            case .gold:     return "Gold"
            case .platinum: return "Platinum"
            case .none:     return "Free"
            }
        }

        /// Lowercase key matching the `tier_name` column in `subscription_tiers_kbuck`.
        var tierKey: String {
            switch self {
            case .silver:   return "silver"
            case .gold:     return "gold"
            case .platinum: return "platinum"
            case .none:     return "free"
            }
        }

        /// Static fallback — used only when remote tierConfigs has not yet loaded.
        fileprivate var fallbackDailyLimit: Int {
            switch self {
            case .silver:   return 10
            case .gold:     return 30
            case .platinum: return Int.max
            case .none:     return 3
            }
        }
    }

    private func tier(for productID: String) -> SubscriptionTier {
        switch productID {
        case "com.kbuck.platinum.monthly":
            return .platinum
        case "com.kbuck.gold.monthly":
            return .gold
        case "com.kbuck.silver.monthly":
            return .silver
        default:
            return .none
        }
    }

    // MARK: - Dynamic Limit Resolver

    /// Resolves the daily fetch limit for the active tier.
    /// Prefers the remote `tierConfigs` value; falls back to static defaults when configs
    /// have not yet been fetched (e.g., first launch before network call completes).
    /// Platinum is always treated as unlimited (Int.max) regardless of DB value.
    func dailyLimit(from configs: [String: TierConfig]) -> Int {
        guard activeSubscriptionTier != .platinum else { return Int.max }
        let key = activeSubscriptionTier.tierKey
        return configs[key]?.daily_fetch_limit ?? activeSubscriptionTier.fallbackDailyLimit
    }

    // MARK: - Transaction Listener

    private var updateListenerTask: Task<Void, Error>? = nil

    // MARK: - Init / Deinit

    init() {
        updateListenerTask = listenForTransactions()
        Task {
            await requestProducts()
            await updateCustomerProductStatus()
            await syncCurrentSubscriptionToSupabase()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Transaction Listener Implementation

    private func listenForTransactions() -> Task<Void, Error> {
        // A detached background task iterates the App Store's async update
        // sequence. Marked nonisolated so the @MainActor hop is explicit.
        return Task(priority: .background) { @MainActor [weak self] in
            guard let self else { return }
            // Iterate over all incoming transaction updates from the App Store.
            // This async sequence never ends while the app is running, covering
            // renewals, revocations, and purchases made on other devices.
            for await verificationResult in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(verificationResult)
                    await self.updateCustomerProductStatus()
                    if transaction.productType == .autoRenewable {
                        await self.syncCurrentSubscriptionToSupabase()
                    }
                    await transaction.finish()
                } catch {
                    self.errorMessage = "Transaction verification failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Fetch Products

    func requestProducts() async {
        isLoading = true
        defer { isLoading = false }

        errorMessage = nil

        let productIdMapping: [String: String] = [
            "silver": "com.kbuck.silver.monthly",
            "gold": "com.kbuck.gold.monthly",
            "platinum": "com.kbuck.platinum.monthly",
            "carfax standard": "com.kbuck.carfax.standard",
            "carfax platinum": "com.kbuck.carfax.platinum"
        ]

        var requestedIDs = Set(StoreManager.consumableIDs)

        do {
            let tierConfigs: [TierConfig] = try await supabase
                .from("subscription_tiers_kbuck")
                .select("tier_name, daily_fetch_limit, max_favorites")
                .execute()
                .value

            for config in tierConfigs {
                let normalizedName = config.tier_name.lowercased()
                if let productID = productIdMapping[normalizedName] {
                    requestedIDs.insert(productID)
                }
            }
        } catch {
            // Keep going with the local StoreKit configuration even if Supabase is unavailable.
            requestedIDs.formUnion(StoreManager.subscriptionIDs)
        }

        do {
            let storeProducts = try await Product.products(for: Array(requestedIDs))

            var fetchedSubscriptions: [Product] = []
            var fetchedConsumables: [Product] = []

            for product in storeProducts {
                switch product.type {
                case .autoRenewable:
                    fetchedSubscriptions.append(product)
                case .consumable:
                    fetchedConsumables.append(product)
                default:
                    break
                }
            }

            subscriptions = fetchedSubscriptions.sorted { $0.price < $1.price }
            consumables = fetchedConsumables

        } catch {
            errorMessage = "Store Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    enum PurchaseError: Error, LocalizedError {
        case verificationFailed
        case pending
        case userCancelled
        case unknown

        var errorDescription: String? {
            switch self {
            case .verificationFailed: return "Purchase verification failed. Please contact support."
            case .pending:            return "Purchase is pending approval."
            case .userCancelled:      return nil
            case .unknown:            return "An unknown error occurred."
            }
        }
    }

    /// Initiates a StoreKit 2 purchase for the given product.
    /// Returns `true` on successful verified purchase, `false` on cancellation.
    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()

        switch result {
        case .success(let verificationResult):
            let transaction = try checkVerified(verificationResult)
            let jwsToken = verificationResult.jwsRepresentation

            // 1. Send JWS to backend — server verifies and derives all plan data
            await syncPlanToSupabase(jwsRepresentation: jwsToken)

            // 2. Finish the transaction with Apple
            await transaction.finish()

            // 3. Update local UI state
            await updateCustomerProductStatus()
            return true

        case .userCancelled:
            return false

        case .pending:
            throw PurchaseError.pending

        @unknown default:
            throw PurchaseError.unknown
        }
    }

    // MARK: - Supabase Plan Sync

    /// Sends only the raw JWS to the backend. The server verifies it cryptographically
    /// and derives plan_tier / next_renewal_date from the Apple-signed payload itself.
    private func syncPlanToSupabase(jwsRepresentation: String) async {
        do {
            try await supabase.functions.invoke(
                "verify-subscription",
                options: FunctionInvokeOptions(
                    body: ["jws": jwsRepresentation]
                )
            )
            print("✅ SUPABASE SECURE SYNC: Server verified and updated the subscription.")
        } catch let FunctionsError.httpError(code, data) {
            let payload = String(data: data, encoding: .utf8) ?? "<non-UTF8 payload: \(data.count) bytes>"
            print("🔴 SUPABASE SECURE SYNC ERROR: httpError(code: \(code), data: \(data.count) bytes)")
            print("🔴 SUPABASE SECURE SYNC PAYLOAD: \(payload)")
        } catch {
            print("🔴 SUPABASE SECURE SYNC ERROR: \(error)")
        }
    }

    private func syncCurrentSubscriptionToSupabase() async {
        var bestPriority = 0

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                guard transaction.productType == .autoRenewable else { continue }

                let priority = priority(for: tier(for: transaction.productID))
                guard priority > bestPriority else { continue }

                bestPriority = priority
                await syncPlanToSupabase(jwsRepresentation: result.jwsRepresentation)
            } catch {
                continue
            }
        }
    }

    private func priority(for tier: SubscriptionTier) -> Int {
        switch tier {
        case .platinum: return 3
        case .gold: return 2
        case .silver: return 1
        case .none: return 0
        }
    }

    // MARK: - Verification

    /// Validates Apple's cryptographic signature on a transaction or renewal info.
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw PurchaseError.verificationFailed
        case .verified(let signedType):
            return signedType
        }
    }

    // MARK: - Entitlement Status

    /// Rebuilds the list of currently active purchased subscriptions and
    /// updates consumable credit counts from current entitlements.
    func updateCustomerProductStatus() async {
        var activeSubs: [Product] = []
        var credits: Int = 0
        var highestPriorityRenewalTier: SubscriptionTier? = nil
        var selectedRenewalDate: Date? = nil
        var selectedRenewalPrice: String? = nil

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                switch transaction.productType {
                case .autoRenewable:
                    if let product = subscriptions.first(where: { $0.id == transaction.productID }) {
                        activeSubs.append(product)
                    }
                    let renewalDetails = await renewalDetails(for: transaction)
                    if let pendingTier = renewalDetails.pendingTier {
                        let pendingSubscriptionTier = subscriptionTier(forTierKey: pendingTier)
                        if pendingSubscriptionTier != .none {
                            let currentPriority = highestPriorityRenewalTier.map(priority(for:)) ?? 0
                            let pendingPriority = priority(for: pendingSubscriptionTier)
                            if pendingPriority > currentPriority {
                                highestPriorityRenewalTier = pendingSubscriptionTier
                                selectedRenewalDate = renewalDetails.expirationDate
                                selectedRenewalPrice = renewalPriceLabel(forTier: pendingSubscriptionTier)
                            }
                        } else {
                            highestPriorityRenewalTier = StoreManager.SubscriptionTier.none
                            selectedRenewalDate = renewalDetails.expirationDate
                            selectedRenewalPrice = nil
                        }
                    } else if highestPriorityRenewalTier == nil {
                        selectedRenewalDate = renewalDetails.expirationDate
                        selectedRenewalPrice = renewalPriceLabel(forProductID: transaction.productID)
                    }
                case .consumable:
                    // Consumables are tracked by counting unfinished/delivered transactions.
                    // In production, tie this to your server-side credit balance.
                    if transaction.productID == "com.kbuck.carfax.standard" ||
                       transaction.productID == "com.kbuck.carfax.platinum" {
                        credits += 1
                    }
                default:
                    break
                }
            } catch {
                // Skip unverified transactions silently.
                continue
            }
        }

        purchasedSubscriptions = activeSubs
        carfaxCredits = credits
        nextRenewalTier = highestPriorityRenewalTier
        nextRenewalDate = selectedRenewalDate
        nextRenewalPrice = selectedRenewalPrice
    }

    private func renewalDetails(for transaction: Transaction) async -> (pendingTier: String?, expirationDate: Date?) {
        let expirationDate = transaction.expirationDate
        guard let groupID = subscriptions.first(where: { $0.id == transaction.productID })?.subscription?.subscriptionGroupID
                ?? subscriptions.compactMap({ $0.subscription?.subscriptionGroupID }).first,
              let statuses = try? await Product.SubscriptionInfo.status(for: groupID) else {
            return (nil, expirationDate)
        }

        for status in statuses {
            guard status.state == .subscribed || status.state == .inGracePeriod || status.state == .inBillingRetryPeriod else {
                continue
            }
            guard let renewalInfo = try? checkVerified(status.renewalInfo) else { continue }
            guard renewalInfo.currentProductID == transaction.productID else { continue }

            if renewalInfo.willAutoRenew == false {
                return ("free", expirationDate)
            }

            let nextProductID = renewalInfo.autoRenewPreference ?? renewalInfo.currentProductID
            guard nextProductID != transaction.productID else {
                return (nil, expirationDate)
            }

            let pendingTier = subscriptionTier(forProductID: nextProductID)?.tierKey
            return (pendingTier, expirationDate)
        }

        return (nil, expirationDate)
    }

    private func subscriptionTier(forProductID productID: String) -> SubscriptionTier? {
        let resolvedTier = tier(for: productID)
        return resolvedTier == .none ? nil : resolvedTier
    }

    private func subscriptionTier(forTierKey tierKey: String) -> SubscriptionTier {
        switch tierKey {
        case "silver":
            return .silver
        case "gold":
            return .gold
        case "platinum":
            return .platinum
        default:
            return .none
        }
    }

    private func renewalPriceLabel(forTier tier: SubscriptionTier) -> String? {
        switch tier {
        case .silver:
            return renewalPriceLabel(forProductID: "com.kbuck.silver.monthly")
        case .gold:
            return renewalPriceLabel(forProductID: "com.kbuck.gold.monthly")
        case .platinum:
            return renewalPriceLabel(forProductID: "com.kbuck.platinum.monthly")
        case .none:
            return nil
        }
    }

    private func renewalPriceLabel(forProductID productID: String) -> String? {
        subscriptions.first(where: { $0.id == productID })?.displayPrice
    }

    private func fetchNextRenewalTier(currentTier: SubscriptionTier) async -> SubscriptionTier? {
        guard let groupID = subscriptions.compactMap({ $0.subscription?.subscriptionGroupID }).first else {
            return nil
        }

        guard let statuses = try? await Product.SubscriptionInfo.status(for: groupID) else {
            return nil
        }

        for status in statuses {
            guard status.state == .subscribed || status.state == .inGracePeriod else { continue }
            guard let renewalInfo = try? checkVerified(status.renewalInfo) else { continue }

            let nextProductID = renewalInfo.autoRenewPreference ?? renewalInfo.currentProductID
            let nextTier = tier(for: nextProductID)
            if nextTier != .none, nextTier != currentTier {
                return nextTier
            }
        }

        return nil
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await updateCustomerProductStatus()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}
