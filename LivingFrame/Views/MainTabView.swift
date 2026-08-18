import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            LibraryView()
                .tabItem { Label("素材库", systemImage: "photo.on.rectangle.angled") }
                .tag(AppTab.library)
            EditorView()
                .tabItem { Label("编辑", systemImage: "wand.and.stars") }
                .tag(AppTab.editor)
            WorksView()
                .tabItem { Label("作品", systemImage: "photo.stack") }
                .tag(AppTab.works)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .magicBackground()
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
}
