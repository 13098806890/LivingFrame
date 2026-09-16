import LivingFrameCore
import SwiftUI

/// Canvas appearance controls shared by the canvas tool and the background inspector.
struct CanvasAppearanceEditor: View {
    let aspect: CanvasAspect
    let backgroundIsTransparent: Bool
    let backgroundIsSolid: Bool
    let backgroundHex: String
    let edgeStyle: CanvasEdgeStyle
    let pattern: BackgroundPatternStyle?
    let onSelectAspect: (CanvasAspect) -> Void
    let onSelectTransparent: () -> Void
    let onSelectColor: (String) -> Void
    let onSelectEdgeStyle: (CanvasEdgeStyle) -> Void
    let onSelectPattern: (BackgroundPatternStyle?) -> Void

    private let colors: [(name: String, hex: String)] = [
        ("白色", "FFFFFF"), ("微信背景色", "EDEDED"), ("黑色", "000000")
    ]

    private var selectedColor: Color {
        backgroundIsTransparent ? LF.brandTint.opacity(0.32) : Color(hex: backgroundHex)
    }

    private var customColorSelected: Bool {
        backgroundIsSolid && !colors.contains { $0.hex == backgroundHex.uppercased() }
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { selectedColor },
            set: { onSelectColor($0.hexRGB) }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            settingGroup("画面比例", subtitle: "导出时使用当前比例") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CanvasAspect.allCases) { option in
                            let isSelected = option == aspect
                            Button { onSelectAspect(option) } label: {
                                VStack(spacing: 7) {
                                    aspectGlyph(option)
                                    Text(option.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(LF.textPrimary)
                                }
                                .frame(width: 66, height: 76)
                                .background(
                                    isSelected ? LF.selectionFill : LF.surface2.opacity(0.42),
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.16),
                                            lineWidth: isSelected ? 1.5 : 1
                                        )
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(2)
                }
            }

            settingGroup("背景颜色", subtitle: "透明背景会保留导出时的透明通道") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button(action: onSelectTransparent) {
                            colorSwatch(title: "透明", isSelected: backgroundIsTransparent) {
                                CheckerboardView()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("透明背景")

                        ForEach(colors, id: \.hex) { color in
                            Button { onSelectColor(color.hex) } label: {
                                colorSwatch(
                                    title: color.name,
                                    isSelected: backgroundIsSolid && backgroundHex.uppercased() == color.hex
                                ) {
                                    Color(hex: color.hex)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        CustomColorPickerTile(
                            selection: customColorBinding,
                            isSelected: customColorSelected,
                            accessibilityLabel: "更多背景颜色"
                        )
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                }
            }

            settingGroup("画布外缘", subtitle: "设置画面与外部背景之间的过渡") {
                HStack(spacing: 8) {
                    ForEach(CanvasEdgeStyle.allCases) { option in
                        let isSelected = option == edgeStyle
                        Button { onSelectEdgeStyle(option) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: edgeSymbol(option))
                                    .font(.system(size: 17, weight: .medium))
                                    .frame(height: 20)
                                Text(option.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .foregroundStyle(isSelected ? LF.selectionText : LF.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 66)
                            .background(
                                isSelected ? LF.selectionFill : LF.surface2.opacity(0.42),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.16),
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }

            BackgroundPatternEditor(style: pattern, onChange: onSelectPattern)
        }
    }

    private func aspectGlyph(_ option: CanvasAspect) -> some View {
        let size = option.canvasSize
        let scale = 34 / max(size.width, size.height)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(selectedColor)
            .frame(width: size.width * scale, height: size.height * scale)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(LF.selectionStroke.opacity(0.72), lineWidth: 1)
            }
            .frame(width: 42, height: 38)
            .accessibilityHidden(true)
    }

    private func colorSwatch<Content: View>(
        title: String,
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 5) {
            content()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.2),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }
            Text(title)
                .font(.caption2)
                .foregroundStyle(LF.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 68, height: 72)
        .contentShape(Rectangle())
    }

    private func edgeSymbol(_ style: CanvasEdgeStyle) -> String {
        switch style {
        case .none: "square"
        case .tornSoft: "scribble.variable"
        case .tornLayered: "rectangle.stack"
        }
    }

    private func settingGroup<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LF.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(LF.brandTint.opacity(0.22), lineWidth: 1)
        }
    }
}

/// Shared rainbow custom-color control used by canvas and element inspectors.
struct CustomColorPickerTile: View {
    let selection: Binding<Color>
    let isSelected: Bool
    let accessibilityLabel: LocalizedStringKey

    var body: some View {
        VStack(spacing: 5) {
            ColorPicker("自定义", selection: selection, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: 44)
                .background(
                    AngularGradient(
                        colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                        center: .center
                    ),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    Image(systemName: isSelected ? "checkmark" : "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.16),
                            lineWidth: isSelected ? 2 : 1
                        )
                        .allowsHitTesting(false)
                }
            Text("自定义")
                .font(.caption2)
                .foregroundStyle(LF.textPrimary)
        }
        .frame(width: 64, height: 72)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Shared selected/unselected treatment for compact single-choice inspector controls.
struct EditorOptionChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? LF.selectionText : LF.textPrimary)
                .padding(.horizontal, 12)
                .frame(minWidth: 56, minHeight: 40)
                .background(
                    isSelected ? LF.selectionFill : LF.surface2.opacity(0.42),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.16),
                            lineWidth: isSelected ? 1.5 : 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
