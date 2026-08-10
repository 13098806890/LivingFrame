import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("素材库", systemImage: "photo.on.rectangle.angled") }
            EditorView()
                .tabItem { Label("编辑", systemImage: "wand.and.stars") }
            WorksView()
                .tabItem { Label("作品", systemImage: "photo.stack") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .magicBackground()
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
}
