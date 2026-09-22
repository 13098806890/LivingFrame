import Foundation
import StoreKit
import SwiftUI

@MainActor
final class PurchaseManager: ObservableObject {
    static let weeklyProductID = "com.livingframe.app.pro.weekly"
    static let annualProductID = "com.livingframe.app.pro.annual"
    static let lifetimeProductID = "com.livingframe.app.pro.lifetime"
    static let subscriptionGroupID = "22389365"
    static let freeMaximumExtractionDuration = 5.0
    static let proMaximumExtractionDuration = 10.0

    private static let productIDs: Set<String> = [
        weeklyProductID,
        annualProductID,
        lifetimeProductID
    ]

    @Published private(set) var hasPro = false
    @Published private(set) var hasActiveSubscription = false
    @Published private(set) var hasLifetimePurchase = false
    @Published private(set) var entitlementsLoaded = false

    func allowedExtractionDuration(configuredDuration: Double) -> Double {
        min(
            configuredDuration,
            hasPro ? Self.proMaximumExtractionDuration : Self.freeMaximumExtractionDuration
        )
    }

    private var transactionUpdatesTask: Task<Void, Never>?

    init() {
        transactionUpdatesTask = observeTransactionUpdates()
        Task { await refreshEntitlements() }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func refreshEntitlements() async {
        var hasProEntitlement = false
        var hasActiveSubscription = false
        var hasLifetimePurchase = false

        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  transaction.revocationDate == nil,
                  Self.productIDs.contains(transaction.productID) else { continue }

            if transaction.productID == Self.lifetimeProductID {
                hasProEntitlement = true
                hasLifetimePurchase = true
            } else if transaction.expirationDate.map({ $0 > .now }) == true {
                hasProEntitlement = true
                hasActiveSubscription = true
            }
        }

        hasPro = hasProEntitlement
        self.hasActiveSubscription = hasActiveSubscription
        self.hasLifetimePurchase = hasLifetimePurchase
        self.entitlementsLoaded = true
    }

    func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            await handlePurchaseCompletion(.success(result))
        } catch {
            await handlePurchaseCompletion(.failure(error))
        }
    }

    func handlePurchaseCompletion(_ result: Result<Product.PurchaseResult, any Error>) async {
        if case let .success(.success(.verified(transaction))) = result,
           Self.productIDs.contains(transaction.productID) {
            await refreshEntitlements()
            await transaction.finish()
        } else {
            await refreshEntitlements()
        }
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self,
                      case let .verified(transaction) = result,
                      Self.productIDs.contains(transaction.productID) else { continue }

                await self.refreshEntitlements()
                await transaction.finish()
            }
        }
    }
}
