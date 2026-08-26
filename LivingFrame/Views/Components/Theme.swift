import SwiftUI

// MARK: - 主题色

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

struct ThemePalette {
    let background: Color
    let surface: Color
    let surface2: Color
    let actionPrimary: Color
    let actionDeep: Color
    let brandTint: Color
    let selectionSurface: Color
    let folderIcon: Color
    let accent: Color
    let destructive: Color
    let textPrimary: Color
    let textSecondary: Color
    let timelineClip: Color
    let timelineBackground: Color
    let timelineSticker: Color
    let timelineEffect: Color
    let timelineAudio: Color
}

/// 四套可切换的马卡龙皮肤。首五个颜色分别对应用户给出的主色、深色、强调色、文字色和中性色，
/// 其余颜色是为背景、选中态和可读性补充的语义色。
enum AppTheme: String, CaseIterable, Identifiable {
    case skyPetal
    case coralNavy
    case limeClover
    case gardenSun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skyPetal: "天空花瓣"
        case .coralNavy: "珊瑚海"
        case .limeClover: "青柠麦田"
        case .gardenSun: "花园向日葵"
        }
    }

    var subtitle: String {
        switch self {
        case .skyPetal: "清透、轻盈、最接近 Liquid Glass"
        case .coralNavy: "热情、时尚、对比鲜明"
        case .limeClover: "自然、明亮、带一点复古感"
        case .gardenSun: "清新、活泼、适合创作场景"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .skyPetal:
            return ThemePalette(
                background: Color(hex: "F4FAFD"),
                surface: Color(hex: "FFFFFF"),
                surface2: Color(hex: "DEE4E9"),
                actionPrimary: Color(hex: "47A0C9"),
                actionDeep: Color(hex: "277FA9"),
                brandTint: Color(hex: "95CEE8"),
                selectionSurface: Color(hex: "DDF2FB"),
                folderIcon: Color(hex: "47A0C9"),
                accent: Color(hex: "DF8CAD"),
                destructive: Color(hex: "D6576E"),
                textPrimary: Color(hex: "0E0E0E"),
                textSecondary: Color(hex: "5F707B"),
                timelineClip: Color(hex: "47A0C9"),
                timelineBackground: Color(hex: "95CEE8"),
                timelineSticker: Color(hex: "DF8CAD"),
                timelineEffect: Color(hex: "DF8CAD"),
                timelineAudio: Color(hex: "95CEE8")
            )
        case .coralNavy:
            return ThemePalette(
                background: Color(hex: "FFF5F0"),
                surface: Color(hex: "FFFDFC"),
                surface2: Color(hex: "E4D8CF"),
                actionPrimary: Color(hex: "EC6541"),
                actionDeep: Color(hex: "00283D"),
                brandTint: Color(hex: "F9815E"),
                selectionSurface: Color(hex: "FFE2D9"),
                folderIcon: Color(hex: "EC6541"),
                accent: Color(hex: "00283D"),
                destructive: Color(hex: "D7443C"),
                textPrimary: Color(hex: "131313"),
                textSecondary: Color(hex: "6E625D"),
                timelineClip: Color(hex: "EC6541"),
                timelineBackground: Color(hex: "F9815E"),
                timelineSticker: Color(hex: "00283D"),
                timelineEffect: Color(hex: "F9815E"),
                timelineAudio: Color(hex: "00283D")
            )
        case .limeClover:
            return ThemePalette(
                background: Color(hex: "F6FAEE"),
                surface: Color(hex: "FFFFFF"),
                surface2: Color(hex: "E8E8E8"),
                actionPrimary: Color(hex: "4AA112"),
                actionDeep: Color(hex: "32770D"),
                brandTint: Color(hex: "E7F0D6"),
                selectionSurface: Color(hex: "E2F2D3"),
                folderIcon: Color(hex: "4AA112"),
                accent: Color(hex: "D4B01D"),
                destructive: Color(hex: "D45050"),
                textPrimary: Color(hex: "1C1A1B"),
                textSecondary: Color(hex: "687066"),
                timelineClip: Color(hex: "4AA112"),
                timelineBackground: Color(hex: "E7F0D6"),
                timelineSticker: Color(hex: "D4B01D"),
                timelineEffect: Color(hex: "D4B01D"),
                timelineAudio: Color(hex: "4AA112")
            )
        case .gardenSun:
            return ThemePalette(
                background: Color(hex: "F3F8F4"),
                surface: Color(hex: "FFFFFF"),
                surface2: Color(hex: "D9D9D9"),
                actionPrimary: Color(hex: "3E8257"),
                actionDeep: Color(hex: "2E6643"),
                brandTint: Color(hex: "4E8F38"),
                selectionSurface: Color(hex: "DDF0E3"),
                folderIcon: Color(hex: "4E8F38"),
                accent: Color(hex: "FFC64A"),
                destructive: Color(hex: "D6504B"),
                textPrimary: Color(hex: "000000"),
                textSecondary: Color(hex: "68716B"),
                timelineClip: Color(hex: "3E8257"),
                timelineBackground: Color(hex: "4E8F38"),
                timelineSticker: Color(hex: "FFC64A"),
                timelineEffect: Color(hex: "FFC64A"),
                timelineAudio: Color(hex: "4E8F38")
            )
        }
    }
}

enum LF {
    /// 主题由 AppState 持久化并在设置页切换；这里保留语义 token，避免视图层散落色值。
    private static var currentTheme: AppTheme = .skyPetal

    static func apply(_ theme: AppTheme) {
        currentTheme = theme
    }

    private static var palette: ThemePalette { currentTheme.palette }
    static var background: Color { palette.background }
    static var surface: Color { palette.surface }
    static var surface2: Color { palette.surface2 }
    static var actionPrimary: Color { palette.actionPrimary }
    static var brandTint: Color { palette.brandTint }
    static var selectionSurface: Color { palette.selectionSurface }
    static var folderIcon: Color { palette.folderIcon }
    static var destructive: Color { palette.destructive }
    static var textPrimary: Color { palette.textPrimary }
    static var textSecondary: Color { palette.textSecondary }
    static var timelineClip: Color { palette.timelineClip }
    static var timelineBackground: Color { palette.timelineBackground }
    static var timelineSticker: Color { palette.timelineSticker }
    static var timelineEffect: Color { palette.timelineEffect }
    static var timelineAudio: Color { palette.timelineAudio }

    /// 兼容既有调用点。新代码请按用途使用语义 token。
    static var accent: Color { palette.accent }
    static var accentSoft: Color { selectionSurface }
    static var accentDeep: Color { palette.actionDeep }
    static var magic: Color { brandTint }
    static var gold: Color { actionPrimary }
    static var goldDeep: Color { palette.actionDeep }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [actionPrimary, palette.actionDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 兼容既有调用点。
    static var goldGradient: LinearGradient { accentGradient }
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
        .background(LF.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(LF.brandTint.opacity(0.26), lineWidth: 0.8)
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
