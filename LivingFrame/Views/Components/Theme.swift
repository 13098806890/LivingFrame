import SwiftUI

// MARK: - 主题色（魔法深色系）

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")
        Scanner(string: hexString).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

enum LF {
    static let background = Color(hex: "0B0E1A")
    static let surface = Color(hex: "171A2E")
    static let surface2 = Color(hex: "1F2440")
    static let gold = Color(hex: "E8C05C")
    static let goldDeep = Color(hex: "8C6D2F")
    static let magic = Color(hex: "8B7CF6")
    static let textPrimary = Color(hex: "F2F3F7")
    static let textSecondary = Color(hex: "9AA0B4")

    static let goldGradient = LinearGradient(
        colors: [Color(hex: "F0D78C"), Color(hex: "D4A93C")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - 组件样式

struct MagicButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(prominent ? Color(hex: "1A1405") : LF.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(prominent ? AnyShapeStyle(LF.goldGradient) : AnyShapeStyle(Color.clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(LF.gold.opacity(prominent ? 0 : 0.5), lineWidth: 1)
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
        .background(LF.surface, in: RoundedRectangle(cornerRadius: 16))
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

/// 深色主题背景修饰
struct MagicBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(LF.background.ignoresSafeArea())
            .toolbarBackground(LF.surface.opacity(0.6), for: .navigationBar, .tabBar)
    }
}

extension View {
    func magicBackground() -> some View {
        modifier(MagicBackground())
    }
}
