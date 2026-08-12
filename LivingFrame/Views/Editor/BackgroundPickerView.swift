import LivingFrameCore
import PhotosUI
import SwiftUI

/// 背景选择器：相册图片 / 纯色（白色、微信聊天背景色、黑色）
struct BackgroundPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItems: [PhotosPickerItem] = []

    /// 纯色背景
    private let colors: [(name: String, hex: String)] = [
        ("白色", "FFFFFF"),
        ("微信背景色", "EDEDED"),
        ("黑色", "000000")
    ]

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    aspectSection
                    presetSection
                    patternSection
                    albumSection
                    colorSection
                }
                .padding()
            }
            .navigationTitle("背景与画布")
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

    // MARK: - 线条图案（代码绘制：样式/粗细/颜色）

    /// 线条图案可选颜色
    private let patternColors: [(name: String, hex: String)] = [
        ("灰", "B8BDC9"), ("黑", "000000"), ("金", "E8C05C"),
        ("红", "E74C3C"), ("蓝", "54A0FF"), ("绿", "1DD1A1"),
        ("紫", "8B7CF6"), ("粉", "FF9FF3")
    ]

    /// 线条粗细
    private let patternWidths: [(title: String, width: CGFloat)] = [
        ("细", 1), ("中", 2), ("粗", 4)
    ]

    /// 当前生效的图案参数（用于选中态判断）
    private var currentPattern: BackgroundPatternStyle? {
        guard let bg = appState.composition?.background, bg.kind == .pattern else { return nil }
        return bg.patternStyle
    }

    private var patternSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("线条图案")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LF.textSecondary)
                .textCase(.uppercase)
                .tracking(1.2)
            // 样式
            HStack(spacing: 8) {
                ForEach(BackgroundPattern.allCases) { pattern in
                    Button {
                        applyPattern { $0.pattern = pattern }
                    } label: {
                        Text(pattern.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                currentPattern?.pattern == pattern ? LF.gold : LF.surface2,
                                in: Capsule()
                            )
                            .foregroundStyle(currentPattern?.pattern == pattern ? .black : LF.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // 粗细
            HStack(spacing: 8) {
                ForEach(patternWidths, id: \.width) { width in
                    Button {
                        applyPattern { $0.lineWidth = width.width }
                    } label: {
                        Text(width.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                abs((currentPattern?.lineWidth ?? 0) - width.width) < 0.1 ? LF.gold : LF.surface2,
                                in: Capsule()
                            )
                            .foregroundStyle(abs((currentPattern?.lineWidth ?? 0) - width.width) < 0.1 ? .black : LF.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // 颜色
            HStack(spacing: 10) {
                ForEach(patternColors, id: \.hex) { color in
                    Button {
                        applyPattern { $0.colorHex = color.hex }
                    } label: {
                        Circle()
                            .fill(Color(hex: color.hex))
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle().stroke(
                                    currentPattern?.colorHex == color.hex ? LF.gold : LF.surface2,
                                    lineWidth: currentPattern?.colorHex == color.hex ? 2.5 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 修改图案参数并应用（保留未修改的参数）
    private func applyPattern(_ mutate: (inout BackgroundPatternStyle) -> Void) {
        var style = currentPattern ?? BackgroundPatternStyle()
        mutate(&style)
        appState.setBackgroundPattern(style)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("预置图片")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LF.textSecondary)
                .textCase(.uppercase)
                .tracking(1.2)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(BackgroundStore.shared.presets, id: \.fileName) { preset in
                    presetCell(preset)
                }
            }
        }
    }

    private func presetCell(_ preset: (fileName: String, title: String)) -> some View {
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

    // MARK: - 画布比例

    private var aspectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("画布比例")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LF.textSecondary)
                .textCase(.uppercase)
                .tracking(1.2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CanvasAspect.allCases) { aspect in
                        Button {
                            appState.setCanvasAspect(aspect)
                        } label: {
                            Text(aspect.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    isCurrentAspect(aspect) ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(isCurrentAspect(aspect) ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func isCurrentAspect(_ aspect: CanvasAspect) -> Bool {
        guard let comp = appState.composition else { return false }
        return CanvasAspect.aspect(for: comp.canvasRect.size) == aspect
    }

    // MARK: - 相册图片

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("相册图片")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LF.textSecondary)
                .textCase(.uppercase)
                .tracking(1.2)
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 1, matching: .images) {
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LF.surface2)
                        .frame(height: 110)
                        .overlay {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title2)
                                .foregroundStyle(LF.gold)
                        }
                    Text("从相册选择")
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

    // MARK: - 纯色

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("纯色")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LF.textSecondary)
                .textCase(.uppercase)
                .tracking(1.2)
            HStack(spacing: 10) {
                ForEach(colors, id: \.hex) { color in
                    Button {
                        appState.setBackground(color: color.hex)
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(hex: color.hex))
                                .frame(width: 70, height: 70)
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

    private func selectedBorder(_ key: String) -> Color {
        guard let bg = appState.composition?.background else { return .clear }
        if case .solid = bg.kind, bg.topColor == key {
            return LF.gold
        }
        return .clear
    }
}
