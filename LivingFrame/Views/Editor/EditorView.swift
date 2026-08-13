import LivingFrameCore
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAssetPicker = false
    @State private var showBackgroundPicker = false

    private let timer = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 画布区：占满剩余空间，画布在内部居中缩放（任何比例完整可见）
                CanvasView()
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 时间轴（固定紧凑高度）
                TimelineView()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                // 底部控制区：工具行 + 属性面板
                VStack(spacing: 8) {
                    toolbar
                        .padding(.horizontal, 12)
                    if hasSelection {
                        ElementInspectorView()
                            .padding(.horizontal, 12)
                            .frame(maxHeight: 210)
                    }
                }
                .padding(.vertical, 10)
            }
            .navigationTitle("")
            .magicBackground()
            .onReceive(timer) { _ in
                appState.tick()
            }
            .onAppear {
                appState.ensureComposition()
                appState.selectBackground()
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

    /// 有选中对象（背景/元素/音频）时显示属性面板
    private var hasSelection: Bool {
        appState.selectedBackground
            || !appState.selectedElementIDs.isEmpty
            || appState.selectedAudioID != nil
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolbarButton("photo.on.rectangle.angled", prominent: false) {
                showAssetPicker = true
            }
            toolbarButton("photo", prominent: false) {
                showBackgroundPicker = true
            }
            toolbarButton("crop", prominent: false) {
                appState.isCropping = true
            }
            toolbarButton("square.and.arrow.up", prominent: true) {
                appState.showExportView = true
            }
        }
    }

    private func toolbarButton(
        _ systemImage: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
        .buttonStyle(MagicButtonStyle(prominent: prominent))
    }
}
