import LivingFrameCore
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var appState: AppState

    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if appState.composition != nil {
                    VStack(spacing: 12) {
                        CanvasView()
                            .padding(.horizontal, 12)
                        TimelineView()
                            .padding(.horizontal, 12)
                        ElementInspectorView()
                            .padding(.horizontal, 12)
                        toolbar
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                } else {
                    emptyState
                }
            }
            .navigationTitle("编辑")
            .magicBackground()
            .onReceive(timer) { _ in
                appState.tick()
            }
            .sheet(isPresented: $appState.showTemplatePicker) {
                TemplatePickerView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $appState.showEffectPicker) {
                EffectPickerView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $appState.showExportView) {
                ExportView()
                    .environmentObject(appState)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                icon: "rectangle.3.group",
                title: "画布是空的",
                message: "从「素材库」选择一段视频抠出人物，\n或先套用一个内置模板"
            )
            Button {
                appState.showTemplatePicker = true
            } label: {
                Label("选择内置模板", systemImage: "wand.and.stars")
            }
            .buttonStyle(MagicButtonStyle())
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            toolbarButton("模板", systemImage: "rectangle.3.group", prominent: false) {
                appState.showTemplatePicker = true
            }
            toolbarButton("特效", systemImage: "sparkles", prominent: false) {
                appState.showEffectPicker = true
            }
            toolbarButton("导出", systemImage: "square.and.arrow.up", prominent: true) {
                appState.showExportView = true
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
