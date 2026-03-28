import Foundation
import StoreKit
import Combine

@MainActor
final class StoreManager: ObservableObject {

    // MARK: - Published State

    @Published var subscriptions: [Product] = []
    @Published var consumables: [Product] = []
    @Published var purchasedSubscriptions: [Product] = []
    @Published var carfaxCredits: Int = 0
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

        /// HPD searches included per month for each tier
        var hpdSearchLimit: Int {
            switch self {
            case .silver:   return 10
            case .gold:     return 30
            case .platinum: return Int.max
            case .none:     return 3
            }
        }
    }

    // MARK: - Transaction Listener

    private var updateListenerTask: Task<Void, Error>? = nil

    // MARK: - Init / Deinit

    init() {
        updateListenerTask = listenForTransactions()
        Task {
            await requestProducts()
            await updateCustomerProductStatus()
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

        do {
            let storeProducts = try await Product.products(for: StoreManager.allProductIDs)

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

            // Sort subscriptions by price ascending (Silver → Gold → Platinum)
            subscriptions = fetchedSubscriptions.sorted { $0.price < $1.price }
            consumables = fetchedConsumables

        } catch {
            errorMessage = "Failed to fetch products: \(error.localizedDescription)"
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
            await updateCustomerProductStatus()
            await transaction.finish()
            return true

        case .userCancelled:
            return false

        case .pending:
            throw PurchaseError.pending

        @unknown default:
            throw PurchaseError.unknown
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

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                switch transaction.productType {
                case .autoRenewable:
                    if let product = subscriptions.first(where: { $0.id == transaction.productID }) {
                        activeSubs.append(product)
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
