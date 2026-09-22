import SwiftUI

@main
struct LivingFrameApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var purchaseManager = PurchaseManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BundledFontManager.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .environmentObject(purchaseManager)
                .preferredColorScheme(.light)
                .tint(LF.gold)
                .task {
                    appState.cleanupStaleTemporaryFiles()
                }
#if DEBUG
                .task {
                    await UIAuditFixtureSeeder.seedIfRequested(into: appState)
                }
#endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // StoreKit 的订阅状态可能在 App 位于后台时发生变化；
                // 回到前台后重新读取当前权益，避免过期/撤销订阅继续保留 Pro。
                Task { @MainActor in
                    await purchaseManager.refreshEntitlements()
                }
            }
            guard phase == .inactive || phase == .background else { return }
            appState.persistUserSettings()
            // 自动保存不能依赖应用被 kill 时一定会收到终止回调；
            // 进入后台/非活跃状态是系统给出的最后可靠保存机会。
            Task { @MainActor in
                _ = await appState.saveCurrentDraftNow()
            }
        }
    }
}
