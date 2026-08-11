import LivingFrameCore
import PhotosUI
import SwiftUI

/// 背景选择器：预置图片 / 系统相册图片 / 纯色
struct BackgroundPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItems: [PhotosPickerItem] = []

    /// 常用纯色背景
    private let colors: [(name: String, hex: String)] = [
        ("黑色", "000000"), ("白色", "FFFFFF"),
        ("深蓝", "12162B"), ("墨绿", "0F2A1D"),
        ("酒红", "3A1118"), ("深紫", "241A3A"),
        ("金色", "E8C05C"), ("浅灰", "E8E8EE")
    ]

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    presetSection
                    colorSection
                }
                .padding()
            }
            .navigationTitle("选择背景")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 预置图片

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("预置图片")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LF.textSecondary)
                .textCase(.uppercase)
                .tracking(1.2)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(BackgroundStore.shared.presets, id: \.fileName) { preset in
                    Button {
                        appState.setBackground(preset: preset.fileName)
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            backgroundThumb(preset.fileName)
                                .frame(height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selectedBorder(preset.fileName), lineWidth: 2)
                                }
                            Text(preset.title)
                                .font(.caption)
                                .foregroundStyle(LF.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 1, matching: .images) {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LF.surface2)
                            .frame(height: 90)
                            .overlay {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title2)
                                    .foregroundStyle(LF.gold)
                            }
                        Text("相册图片")
                            .font(.caption)
                            .foregroundStyle(LF.textPrimary)
                    }
                }
                .onChange(of: pickerItems) { _, items in
                    guard let item = items.first else { return }
                    pickerItems.removeAll()
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            appState.setBackground(imageData: data)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 纯色

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("纯色")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LF.textSecondary)
                .textCase(.uppercase)
                .tracking(1.2)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(colors, id: \.hex) { color in
                    Button {
                        appState.setBackground(color: color.hex)
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(hex: color.hex))
                                .frame(height: 50)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selectedBorder(color.hex), lineWidth: 2)
                                }
                            Text(color.name)
                                .font(.caption)
                                .foregroundStyle(LF.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func backgroundThumb(_ fileName: String) -> some View {
        Group {
            if let cgImage = BackgroundStore.shared.loadImage(named: fileName) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func selectedBorder(_ key: String) -> Color {
        isCurrent(key) ? LF.gold : Color.clear
    }

    private func isCurrent(_ key: String) -> Bool {
        guard let bg = appState.composition?.background else { return false }
        switch bg.kind {
        case .solid, .gradient:
            return key == bg.topColor
        case .image:
            return bg.imageFileName == key
        case .clear:
            return false
        }
    }
}
