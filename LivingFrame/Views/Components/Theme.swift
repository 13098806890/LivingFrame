import SwiftUI

// MARK: - 主题色（Cloud Glass：浅色系统背景 + iOS 蓝）

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")
        guard hexString.count == 6, Scanner(string: hexString).scanHexInt64(&value) else {
            // 非法输入回退为中灰，避免静默变黑
            self.init(red: 0.5, green: 0.5, blue: 0.5)
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

enum LF {
    /// 使用系统语义色，浅色/深色模式和提高对比度设置都能自动适配。
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surface2 = Color(uiColor: .tertiarySystemFill)
    static let accent = Color(uiColor: .systemBlue)
    static let accentSoft = Color(hex: "DCEBFF")
    static let accentDeep = Color(hex: "356DB5")
    static let magic = Color(uiColor: .systemIndigo)
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)

    /// 兼容现有调用点：原 gold 语义统一映射到 iOS 蓝，不再使用黑金配色。
    static let gold = accent
    static let goldDeep = accentDeep

    static let accentGradient = LinearGradient(
        colors: [Color(hex: "3D9BFF"), Color(hex: "0A84FF")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// 兼容现有调用点。
    static let goldGradient = accentGradient
}

// MARK: - 组件样式

struct MagicButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(prominent ? .white : LF.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(prominent ? AnyShapeStyle(LF.accentGradient) : AnyShapeStyle(Color.clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(LF.accent.opacity(prominent ? 0 : 0.5), lineWidth: 1)
                    }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct SectionCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)
                    .textCase(.uppercase)
                    .tracking(1.2)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.45), lineWidth: 0.8)
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(LF.gold.opacity(0.8))
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(LF.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Cloud Glass 背景修饰：内容层使用系统背景，导航栏和 Tab 栏使用系统材质。
struct MagicBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(LF.background.ignoresSafeArea())
            .toolbarBackground(.regularMaterial, for: .navigationBar, .tabBar)
    }
}

extension View {
    func magicBackground() -> some View {
        modifier(MagicBackground())
    }
}
