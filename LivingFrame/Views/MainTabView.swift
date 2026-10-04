import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            LibraryView()
                .tabItem {
                    Label {
                        Text("转换")
                    } icon: {
                        Image(systemName: "livephoto")
                            .symbolEffect(.bounce, value: appState.selectedTab == .library)
                    }
                }
                .tag(AppTab.library)
            EditorView()
                .tabItem {
                    Label {
                        Text("编辑")
                    } icon: {
                        Image(systemName: "wand.and.stars")
                            .symbolEffect(.bounce, value: appState.selectedTab == .editor)
                    }
                }
                .tag(AppTab.editor)
            WorksView()
                .tabItem {
                    Label {
                        Text("作品")
                    } icon: {
                        Image(systemName: "photo.stack")
                            .symbolEffect(.bounce, value: appState.selectedTab == .works)
                    }
                }
                .tag(AppTab.works)
            SettingsView()
                .tabItem {
                    Label {
                        Text("设置")
                    } icon: {
                        Image(systemName: "gearshape")
                            .symbolEffect(.bounce, value: appState.selectedTab == .settings)
                    }
                }
                .tag(AppTab.settings)
        }
        .buttonStyle(LFAnimatedPlainButtonStyle())
        .magicBackground()
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
        .environmentObject(PurchaseManager())
}
