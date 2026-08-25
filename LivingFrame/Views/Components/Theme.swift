import SwiftUI

// MARK: - 主题色（Macaron Sky：相纸暖白 + 可访问天空蓝）

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

    /// 将系统取色器返回的颜色转成工程使用的 6 位 RGB。
    var hexRGB: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "FFFFFF"
        }
        func byte(_ value: CGFloat) -> Int {
            min(max(Int((value * 255).rounded()), 0), 255)
        }
        return String(
            format: "%02X%02X%02X",
            byte(red),
            byte(green),
            byte(blue)
        )
    }
}

enum LF {
    /// 色值均来自 Asset Catalog，因此会自动随浅色、深色和「增强对比度」切换。
    /// 语义名只描述用途，视图层不应直接使用品牌色值或十六进制颜色。
    static let background = Color("AppBackground")
    static let surface = Color("AppSurface")
    static let surface2 = Color("AppSurfaceSecondary")
    static let actionPrimary = Color("BrandAction")
    static let brandTint = Color("BrandTint")
    static let selectionSurface = Color("SelectionSurface")
    static let folderIcon = Color("FolderIcon")
    static let destructive = Color("Destructive")
    static let textPrimary = Color("TextPrimary")
    static let textSecondary = Color("TextSecondary")

    /// 兼容既有调用点。新代码请按用途使用 `actionPrimary`、`selectionSurface` 等语义 token。
    static let accent = actionPrimary
    static let accentSoft = selectionSurface
    static let accentDeep = folderIcon
    static let magic = brandTint
    static let gold = actionPrimary
    static let goldDeep = folderIcon

    static let accentGradient = LinearGradient(
        // 两端都可承载白色按钮文字，避免把浅马卡龙蓝直接放在白字下面。
        colors: [folderIcon, actionPrimary],
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
