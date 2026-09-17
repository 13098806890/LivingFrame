import StoreKit
import SwiftUI

enum GIFBloomStoreLinks {
    private static let siteRoot = "https://13098806890.github.io/App-Store-pages/GIFBloom/"
    private static let standardEULA = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"

    static var privacyPolicy: URL { localizedPage("privacy-policy.html") }
    static var support: URL { localizedPage("support.html") }
    static var termsOfUse: URL { URL(string: standardEULA)! }

    private static func localizedPage(_ page: String) -> URL {
        URL(string: "\(siteRoot)\(page)?lang=\(siteLanguageCode)")!
    }

    private static var siteLanguageCode: String {
        let preferred = (Bundle.main.preferredLocalizations.first ?? "en").lowercased()
        if preferred.hasPrefix("zh-hant") || preferred.hasPrefix("zh-tw") ||
            preferred.hasPrefix("zh-hk") || preferred.hasPrefix("zh-mo") {
            return "zh-Hant"
        }
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        if preferred.hasPrefix("pt") { return "pt-BR" }

        let languageCode = String(preferred.split(separator: "-").first ?? "en")
        let supported = Set([
            "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
            "ru", "th", "tr", "vi"
        ])
        return supported.contains(languageCode) ? languageCode : "en"
    }
}

struct GIFBloomProStoreView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var purchaseManager: PurchaseManager

    var body: some View {
        NavigationStack {
            SubscriptionStoreView(
                productIDs: [
                    PurchaseManager.weeklyProductID,
                    PurchaseManager.annualProductID
                ],
                marketingContent: {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("GIFBloom Pro", systemImage: "sparkles")
                                .font(.title2.weight(.semibold))
                            Text("选择周订阅、年订阅或一次性买断解锁 GIFBloom Pro。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        ProductView(id: PurchaseManager.lifetimeProductID)
                            .productViewStyle(.large)
                            .frame(maxWidth: .infinity)
                            .productDescription(.visible)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("周订阅和年订阅均会自动续订。除非在当前周期结束前至少 24 小时取消，否则会自动续订。你可以在 Apple ID 设置中管理或取消订阅。")
                            Text("一次性买断只需付款一次，可永久解锁 GIFBloom Pro。价格以 App Store 根据你的地区显示的金额为准。")
                            Text("确认购买后，款项将从你的 Apple ID 账户扣除。付款信息由 Apple 处理；GIFBloom 不接收银行卡或付款账户信息。")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                }
            )
            .storeButton(.visible, for: .restorePurchases)
            .storeButton(.visible, for: .policies)
            .storeButton(.hidden, for: .cancellation)
            .subscriptionStoreControlStyle(.picker)
            .subscriptionStoreButtonLabel(.multiline)
            .subscriptionStorePolicyDestination(url: GIFBloomStoreLinks.privacyPolicy, for: .privacyPolicy)
            .subscriptionStorePolicyDestination(url: GIFBloomStoreLinks.termsOfUse, for: .termsOfService)
            .onInAppPurchaseCompletion { _, result in
                await purchaseManager.handlePurchaseCompletion(result)
            }
            .navigationTitle("GIFBloom Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await purchaseManager.refreshEntitlements() }
        .presentationDetents([.large])
    }
}
