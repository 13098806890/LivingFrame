import LivingFrameCore
import SwiftUI
import UIKit

/// 文字编辑面板的共享控件。
/// 编辑工具面板和元素检查器都复用这里，保证文字的字体、字号和颜色行为一致。
struct TextFormattingControls: View {
    @EnvironmentObject private var appState: AppState
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
        ("Marker Felt", "MarkerFelt-Wide")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("输入文字", text: Binding(
                get: { text.text },
                set: { value in appState.updateText(text.id) { $0.text = value } }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.subheadline)

            HStack(spacing: 10) {
                Text("字体")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                Picker("字体", selection: Binding(
                    get: { text.fontName ?? "" },
                    set: { value in appState.updateText(text.id) { $0.fontName = value.isEmpty ? nil : value } }
                )) {
                    Text("系统默认").tag("")
                    ForEach(fonts.filter { UIFont(name: $0.value, size: 16) != nil }, id: \.value) { font in
                        Text(font.name).tag(font.value)
                    }
                }
                .pickerStyle(.menu)
                .tint(LF.selectionText)
            }

            HStack(spacing: 10) {
                Text("字号")
                    .font(.caption2)
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
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LF.textSecondary)
                    .frame(width: 32, alignment: .trailing)
            }

            HStack(spacing: 10) {
                ForEach(colors, id: \.hex) { color in
                    Button {
                        appState.updateText(text.id) { $0.colorHex = color.hex }
                    } label: {
                        Circle()
                            .fill(Color(hex: color.hex))
                            .frame(width: 24, height: 24)
                            .overlay {
                                Circle().stroke(
                                    text.colorHex.uppercased() == color.hex ? LF.selectionStroke : LF.surface2,
                                    lineWidth: text.colorHex.uppercased() == color.hex ? 2.5 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
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
                .frame(width: 26, height: 26)
                .overlay {
                    Circle()
                        .fill(AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center
                        ))
                        .overlay { Image(systemName: "plus").font(.caption2.bold()).foregroundStyle(.white) }
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("更多文字颜色")
            }
        }
    }
}
