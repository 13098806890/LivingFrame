import LivingFrameCore
import SwiftUI

/// Shared controls for the composition background pattern, used by both the canvas panel and inspector.
struct BackgroundPatternEditor: View {
    let style: BackgroundPatternStyle?
    let onChange: (BackgroundPatternStyle?) -> Void

    private struct SizeOption {
        let title: LocalizedStringKey
        let value: CGFloat
    }

    private static let lineWidthOptions = [
        SizeOption(title: "细", value: 2),
        SizeOption(title: "中", value: 4),
        SizeOption(title: "粗", value: 8)
    ]
    private static let lineSpacingOptions = [
        SizeOption(title: "稀疏", value: 48),
        SizeOption(title: "中", value: 36),
        SizeOption(title: "密集", value: 24)
    ]
    private static let mosaicSizeOptions = [
        SizeOption(title: "小", value: 32),
        SizeOption(title: "中", value: 48),
        SizeOption(title: "大", value: 64)
    ]
    private static let colorHexes = [
        "FFFFFF", "000000", "B8BDC9", "E8C05C", "E74C3C",
        "FF9FF3", "54A0FF", "1DD1A1", "8B7CF6"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("图案叠加")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.textPrimary)
                Text("为背景添加线条或马赛克纹理；选择“无”可随时关闭。")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                patternButton(
                    title: "无",
                    symbol: "circle.slash",
                    isSelected: style == nil
                ) {
                    onChange(nil)
                }

                ForEach(BackgroundPattern.allCases) { pattern in
                    patternButton(
                        title: LocalizedStringKey(pattern.title),
                        symbol: symbol(for: pattern),
                        isSelected: style?.pattern == pattern
                    ) {
                        select(pattern)
                    }
                }
            }

            if let style {
                Rectangle()
                    .fill(LF.brandTint.opacity(0.16))
                    .frame(height: 1)

                if style.pattern == .mosaic {
                    optionRow(
                        title: "方块大小",
                        options: Self.mosaicSizeOptions,
                        selected: style.lineWidth,
                        tolerance: 0.1
                    ) { value in
                        updateStyle { $0.lineWidth = value }
                    }
                } else {
                    optionRow(
                        title: "线条粗细",
                        options: Self.lineWidthOptions,
                        selected: style.lineWidth,
                        tolerance: 0.1
                    ) { value in
                        updateStyle { $0.lineWidth = value }
                    }

                    optionRow(
                        title: "线条间距",
                        options: Self.lineSpacingOptions,
                        selected: style.spacing,
                        tolerance: 1
                    ) { value in
                        updateStyle { $0.spacing = value }
                    }
                }

                colorPicker(selectedHex: style.colorHex)

                if style.pattern != .mosaic {
                    angleControl
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LF.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LF.brandTint.opacity(0.24), lineWidth: 1)
        }
    }

    private var angleControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("角度")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LF.textSecondary)
                Spacer()
                Text("\(Int(style?.angle ?? 0))°")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(LF.textPrimary)
                    .contentTransition(.numericText())
            }
            Slider(
                value: Binding(
                    get: { style?.angle ?? 0 },
                    set: { value in updateStyle { $0.angle = value } }
                ),
                in: 0...180
            )
            .tint(LF.selectionStroke)
            .accessibilityLabel(Text("角度"))
        }
    }

    private func patternButton(
        title: LocalizedStringKey,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? LF.selectionText : LF.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                isSelected ? LF.selectionFill : LF.surface2.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.14),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func optionRow(
        title: LocalizedStringKey,
        options: [SizeOption],
        selected: CGFloat,
        tolerance: CGFloat,
        onSelect: @escaping (CGFloat) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(LF.textSecondary)

            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    let isSelected = abs(selected - option.value) <= tolerance
                    Button {
                        onSelect(option.value)
                    } label: {
                        Text(option.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? LF.selectionText : LF.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                isSelected ? LF.selectionFill : LF.surface2.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.14),
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func colorPicker(selectedHex: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("图案颜色")
                .font(.caption.weight(.medium))
                .foregroundStyle(LF.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.colorHexes, id: \.self) { hex in
                        let isSelected = selectedHex.uppercased() == hex
                        Button {
                            updateStyle { $0.colorHex = hex }
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 27, height: 27)
                                .overlay {
                                    Circle().strokeBorder(
                                        isSelected ? LF.selectionStroke : LF.surface2,
                                        lineWidth: isSelected ? 2.5 : 1
                                    )
                                }
                                .overlay {
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(hex == "FFFFFF" ? LF.textPrimary : .white)
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("图案颜色"))
                        .accessibilityValue(Text(hex))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func select(_ pattern: BackgroundPattern) {
        var next = style ?? BackgroundPatternStyle()
        next.pattern = pattern
        if pattern == .mosaic {
            next.lineWidth = 48
            next.spacing = 48
            next.angle = 0
        } else {
            next.lineWidth = 4
            next.spacing = 36
            next.angle = 0
        }
        onChange(next)
    }

    private func updateStyle(_ update: (inout BackgroundPatternStyle) -> Void) {
        guard var next = style else { return }
        update(&next)
        onChange(next)
    }

    private func symbol(for pattern: BackgroundPattern) -> String {
        switch pattern {
        case .horizontal: "line.3.horizontal"
        case .mosaic: "square.grid.3x3"
        }
    }
}
