import SwiftUI

@main
struct LivingFrameApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
        .preferredColorScheme(.light)
                .tint(LF.gold)
        }
    }
}
