import Foundation
import StoreKit
import SwiftUI

@MainActor
final class PurchaseManager: ObservableObject {
    static let weeklyProductID = "com.livingframe.app.pro.weekly"
    static let monthlyProductID = "com.livingframe.app.pro.monthly"
    static let annualProductID = "com.livingframe.app.pro.annual"
    static let lifetimeProductID = "com.livingframe.app.pro.lifetime"
    static let subscriptionGroupID = "22389365"

    private static let subscriptionProductIDs: Set<String> = [
        weeklyProductID,
        monthlyProductID,
        annualProductID
    ]
    private static let productIDs = subscriptionProductIDs.union([lifetimeProductID])

    @Published private(set) var hasPro = false
    @Published private(set) var hasActiveSubscription = false

    private var transactionUpdatesTask: Task<Void, Never>?

    init() {
        transactionUpdatesTask = observeTransactionUpdates()
        Task { await refreshEntitlements() }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func refreshEntitlements() async {
        var ownsLifetimePurchase = false
        var hasActiveSubscription = false

        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  transaction.revocationDate == nil,
                  Self.productIDs.contains(transaction.productID) else { continue }

            switch transaction.productID {
            case Self.lifetimeProductID:
                ownsLifetimePurchase = true
            case Self.weeklyProductID, Self.monthlyProductID, Self.annualProductID:
                hasActiveSubscription = hasActiveSubscription ||
                    (transaction.expirationDate.map { $0 > .now } ?? false)
            default:
                break
            }
        }

        hasPro = ownsLifetimePurchase || hasActiveSubscription
        self.hasActiveSubscription = hasActiveSubscription
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
