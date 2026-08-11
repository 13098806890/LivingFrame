import LivingFrameCore
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAssetPicker = false
    @State private var showBackgroundPicker = false
    @State private var showAspectPicker = false

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
            .sheet(isPresented: $appState.showEffectPicker) {
                EffectPickerView()
                    .environmentObject(appState)
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
            .sheet(isPresented: $showAspectPicker) {
                AspectPickerView()
                    .environmentObject(appState)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                icon: "rectangle.3.group",
                title: "开始创作",
                message: "先选择画布比例，\n再从素材库选人物、选背景开始"
            )
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(CanvasAspect.allCases) { aspect in
                        Button {
                            appState.createComposition(aspect: aspect)
                        } label: {
                            Text(aspect.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(LF.surface2, in: Capsule())
                                .foregroundStyle(LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        showAssetPicker = true
                    } label: {
                        Label("选择素材", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(MagicButtonStyle(prominent: false))
                    .disabled(appState.composition == nil)
                    Button {
                        showBackgroundPicker = true
                    } label: {
                        Label("选择背景", systemImage: "paintbrush.pointed")
                    }
                    .buttonStyle(MagicButtonStyle(prominent: false))
                    .disabled(appState.composition == nil)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            toolbarButton("素材", systemImage: "photo.on.rectangle.angled", prominent: false) {
                showAssetPicker = true
            }
            toolbarButton("背景", systemImage: "paintbrush.pointed", prominent: false) {
                showBackgroundPicker = true
            }
            toolbarButton("画布", systemImage: "rectangle.portrait", prominent: false) {
                showAspectPicker = true
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
