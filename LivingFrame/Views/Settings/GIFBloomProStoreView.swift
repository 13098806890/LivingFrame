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
            if !purchaseManager.entitlementsLoaded {
                ProgressView("正在检查购买状态…")
            } else if purchaseManager.hasLifetimePurchase {
                LifetimePurchaseOwnedView()
            } else {
                SubscriptionStoreView(
                productIDs: [
                    PurchaseManager.weeklyProductID,
                    PurchaseManager.annualProductID
                ],
                marketingContent: {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Image("GIFBloomProWordmark")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 210, height: 70, alignment: .leading)
                                .accessibilityLabel("GIFBloom Pro")

                            Label("订阅 GIFBloom Pro 后可去除导出水印。", systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(LF.textPrimary)
                            Label("解锁更长的素材提取时长。", systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(LF.textPrimary)
                        }

                        Text("周订阅和年订阅会自动续订；如需取消，请在当前周期结束前至少 24 小时操作。可在 Apple ID 设置中管理。")
                        .font(.footnote)
                        .foregroundStyle(LF.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                        LifetimePurchaseOption()
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
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
                }
            }
        .task { await purchaseManager.refreshEntitlements() }
        .presentationDetents([.large])
    }
}

private struct LifetimePurchaseOwnedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "infinity.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(LF.actionPrimary)

            Text("已购买 GIFBloom Pro 永久版")
                .font(.headline)
                .foregroundStyle(LF.textPrimary)

            Text("你已永久解锁 Pro 功能，无需订阅。")
                .font(.subheadline)
                .foregroundStyle(LF.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct LifetimePurchaseOption: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @State private var product: Product?
    @State private var isPurchasing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Label("永久买断", systemImage: "infinity.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LF.textPrimary)

            if purchaseManager.hasLifetimePurchase {
                Text("已拥有 GIFBloom Pro 永久权益。")
                    .font(.footnote)
                    .foregroundStyle(LF.textSecondary)
            } else if let product {
                Text(
                    purchaseManager.hasActiveSubscription
                        ? "当前订阅已解锁 Pro；购买永久版后将永久保留 Pro 权益。"
                        : "一次性购买，永久解锁 Pro。"
                )
                    .font(.footnote)
                    .foregroundStyle(LF.textSecondary)

                Button {
                    Task {
                        isPurchasing = true
                        await purchaseManager.purchase(product)
                        isPurchasing = false
                    }
                } label: {
                    HStack {
                        Text("购买永久版")
                        Spacer()
                        if isPurchasing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(product.displayPrice)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPurchasing)
            } else {
                ProgressView("正在加载永久版…")
                    .font(.footnote)
                    .foregroundStyle(LF.textSecondary)
            }
        }
        .task {
            guard product == nil else { return }
            product = try? await Product.products(for: [PurchaseManager.lifetimeProductID]).first
        }
    }
}
