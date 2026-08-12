import LivingFrameCore
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAssetPicker = false
    @State private var showBackgroundPicker = false

    private let timer = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Spacer(minLength: 8)
                    // 画布固定高度，不被下方内容压缩；内容多时向下滚动
                    CanvasView()
                        .frame(height: 420)
                        .padding(.horizontal, 12)
                    TimelineView()
                        .padding(.horizontal, 12)
                    ElementInspectorView()
                        .padding(.horizontal, 12)
                    toolbar
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("")
            .magicBackground()
            .onReceive(timer) { _ in
                appState.tick()
            }
            .onAppear {
                appState.ensureComposition()
            }
            .sheet(isPresented: $appState.showExportView) {
                ExportView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showAssetPicker) {
                AssetPickerView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showBackgroundPicker) {
                BackgroundPickerView()
                    .environmentObject(appState)
            }
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                toolbarButton("素材", systemImage: "photo.on.rectangle.angled", prominent: false) {
                    showAssetPicker = true
                }
            toolbarButton("背景", systemImage: "paintbrush.pointed", prominent: false) {
                showBackgroundPicker = true
            }
            toolbarButton("裁剪", systemImage: "crop", prominent: false) {
                appState.isCropping = true
            }
                toolbarButton("导出", systemImage: "square.and.arrow.up", prominent: true) {
                    appState.showExportView = true
                }
            }
        }
    }

    private func toolbarButton(
        _ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(MagicButtonStyle(prominent: prominent))
    }
}
