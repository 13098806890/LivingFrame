import Foundation
import StoreKit
import SwiftUI

@MainActor
final class PurchaseManager: ObservableObject {
    static let weeklyProductID = "com.livingframe.app.pro.weekly"
    static let annualProductID = "com.livingframe.app.pro.annual"
    static let subscriptionGroupID = "22389365"
    static let freeMaximumExtractionDuration = 5.0
    static let proMaximumExtractionDuration = 10.0

    private static let productIDs: Set<String> = [
        weeklyProductID,
        annualProductID
    ]

    @Published private(set) var hasPro = false
    @Published private(set) var hasActiveSubscription = false

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
        var hasActiveSubscription = false

        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  transaction.revocationDate == nil,
                  Self.productIDs.contains(transaction.productID) else { continue }

            hasActiveSubscription = hasActiveSubscription ||
                (transaction.expirationDate.map { $0 > .now } ?? false)
        }

        hasPro = hasActiveSubscription
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
