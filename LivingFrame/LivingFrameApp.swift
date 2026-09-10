import SwiftUI

@main
struct LivingFrameApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BundledFontManager.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .preferredColorScheme(.light)
                .tint(LF.gold)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .inactive || phase == .background else { return }
            // 自动保存不能依赖应用被 kill 时一定会收到终止回调；
            // 进入后台/非活跃状态是系统给出的最后可靠保存机会。
            Task { @MainActor in
                _ = await appState.saveCurrentDraftNow()
            }
        }
    }
}
