import LivingFrameCore
import SwiftUI
import UIKit

/// 文字编辑面板的共享控件。
/// 编辑工具面板和元素检查器都复用这里，保证文字的字体、字号和颜色行为一致。
struct TextFormattingControls: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var isTextFieldFocused: Bool
    let text: TextElement

    private let colors: [(name: String, hex: String)] = [
        ("白", "FFFFFF"), ("黑", "000000"), ("金", "E8C05C"), ("红", "E74C3C"),
        ("粉", "FF9FF3"), ("蓝", "54A0FF"), ("绿", "1DD1A1"), ("紫", "8B7CF6")
    ]

    private let fonts: [(name: String, value: String)] = [
        ("系统粗体", "HelveticaNeue-Bold"),
        ("Avenir Next", "AvenirNext-Bold"),
        ("Futura", "Futura-Bold"),
        ("Georgia", "Georgia-Bold"),
        ("Courier", "Courier-Bold"),
        ("Marker Felt", "MarkerFelt-Wide"),
        ("思源黑体", "NotoSansSC-Regular"),
        ("Inter", "Inter-Regular")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextControlSection(title: "内容", subtitle: "文字会即时显示在画布上") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "text.cursor")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LF.actionPrimary)
                        .frame(width: 26, height: 26)
                        .background(LF.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        TextField("输入文字", text: Binding(
                            get: { text.text },
                            set: { value in appState.updateText(text.id) { $0.text = value } }
                        ), axis: .vertical)
                        .focused($isTextFieldFocused)
                        .lineLimit(1...3)
                        .font(.body)
                        .foregroundStyle(LF.textPrimary)

                        if isTextFieldFocused {
                            HStack {
                                Spacer()
                                Button {
                                    isTextFieldFocused = false
                                } label: {
                                    Label("收起", systemImage: "keyboard.chevron.compact.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(LF.actionPrimary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(LF.selectionFill, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("收起键盘")
                            }
                        }
                    }
                }
                .padding(12)
                .background(LF.surface2.opacity(0.52), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            TextControlSection(title: "预览", subtitle: "点击字体直接选择") {
                Text(text.text.isEmpty ? "输入文字" : text.text)
                    .font(previewFont)
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.25)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .padding(.horizontal, 12)
                    .background(
                        LinearGradient(
                            colors: [LF.surface2.opacity(0.62), LF.brandTint.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(LF.brandTint.opacity(0.24), lineWidth: 1)
                    }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(fontOptions, id: \.value) { font in
                            Button {
                                appState.updateText(text.id) { $0.fontName = font.value.isEmpty ? nil : font.value }
                            } label: {
                                VStack(spacing: 3) {
                                    Text("text")
                                        .font(fontPreview(for: font))
                                        .foregroundStyle(.black)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.55)
                                    Text(font.name)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(isSelected(font) ? LF.selectionText : LF.textSecondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 86, height: 48)
                                .background(
                                    isSelected(font) ? LF.selectionFill : LF.surface.opacity(0.76),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(
                                            isSelected(font) ? LF.selectionStroke : LF.brandTint.opacity(0.18),
                                            lineWidth: isSelected(font) ? 1.8 : 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("选择字体\(font.name)")
                            .accessibilityAddTraits(isSelected(font) ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            TextControlSection(title: "字号", subtitle: "24–300 pt") {
                HStack(spacing: 12) {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(LF.textSecondary)
                    Slider(
                        value: Binding(
                            get: { Double(text.fontSize) },
                            set: { value in appState.updateText(text.id) { $0.fontSize = CGFloat(value) } }
                        ),
                        in: 24...300
                    )
                    .tint(LF.actionPrimary)
                    Text("\(Int(text.fontSize))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(LF.selectionText)
                        .frame(width: 42, height: 30)
                        .background(LF.selectionFill, in: Capsule())
                }
            }

            TextControlSection(title: "颜色") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(colors, id: \.hex) { color in
                            Button {
                                appState.updateText(text.id) { $0.colorHex = color.hex }
                            } label: {
                                Circle()
                                    .fill(Color(hex: color.hex))
                                    .frame(width: 30, height: 30)
                .overlay {
                                        Circle().stroke(
                                            text.colorHex.uppercased() == color.hex ? LF.selectionStroke : LF.surface2,
                                            lineWidth: text.colorHex.uppercased() == color.hex ? 2.5 : 1
                                        )
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("文字颜色\(color.name)")
                        }
                        ColorPicker(
                            "更多",
                            selection: Binding(
                                get: { Color(hex: text.colorHex) },
                                set: { color in appState.updateText(text.id) { $0.colorHex = color.hexRGB } }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .frame(width: 30, height: 30)
                        .background(
                            AngularGradient(
                                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                center: .center
                            ),
                            in: Circle()
                        )
                        .overlay {
                            Image(systemName: "plus")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .allowsHitTesting(false)
                        }
                        .accessibilityLabel("更多文字颜色")
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var availableFonts: [(name: String, value: String)] {
        let bundledNames = Set([
            "NotoSansSC-Regular",
            "Inter-Regular"
        ])
        return fonts.filter { bundledNames.contains($0.value) || UIFont(name: $0.value, size: 16) != nil }
    }

    private var fontOptions: [(name: String, value: String)] {
        [(name: "系统默认", value: "")] + availableFonts
    }

    private func isSelected(_ font: (name: String, value: String)) -> Bool {
        (text.fontName ?? "") == font.value
    }

    private func fontPreview(for font: (name: String, value: String)) -> Font {
        if font.value.isEmpty {
            return .system(size: 20, weight: .semibold)
        }
        return .custom(font.value, size: 20)
    }

    private var previewFont: Font {
        let size = min(max(text.fontSize, 24), 42)
        if let fontName = text.fontName, !fontName.isEmpty {
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: .semibold)
    }
}

private struct TextControlSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.textPrimary)
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LF.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LF.brandTint.opacity(0.24), lineWidth: 1)
        }
    }
}
