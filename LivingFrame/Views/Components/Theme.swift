import SwiftUI
import UIKit

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
    /// 所有编辑控件共用的选中态：浅色底、主题主色描边、深色文字。
    /// 不直接复用 accent，避免外缘、图案和比例在不同主题下出现不同高亮颜色。
    static var selectionFill: Color { palette.selectionSurface }
    static var selectionStroke: Color { palette.actionPrimary }
    static var selectionText: Color { palette.actionDeep }
    /// 主题提供的第三色，用于页面标题、卡片标题和内容区块标题。
    static var header: Color { palette.accent }
    static var folderIcon: Color { palette.folderIcon }
    static var destructive: Color { palette.destructive }
    static var textPrimary: Color { palette.textPrimary }
    static var textSecondary: Color { palette.textSecondary }
    static var timelineClip: Color { palette.timelineClip }
    static var timelineBackground: Color { palette.timelineBackground }
    static var timelineSticker: Color { palette.timelineSticker }
    static var timelineEffect: Color { palette.timelineEffect }
    static var timelineAudio: Color { palette.timelineAudio }

    /// 兼容尚未迁移的旧调用点。新代码请按用途使用语义 token。
    static var accent: Color { palette.accent }
    static var gold: Color { actionPrimary }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [actionPrimary, palette.actionDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
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
                    .foregroundStyle(LF.header)
                    .textCase(.uppercase)
                    .tracking(1.2)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    LF.surface.opacity(0.96),
                    LF.brandTint.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16)
        )
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

/// 时间轴选区外遮罩：中间选区保持完全透明，只有左右未选帧降低亮度。
/// 编辑页与视频截取页共用，确保两处呈现相同的
/// “未选帧（暗） | 选中帧（原色） | 未选帧（暗）”效果。
struct TimelineInactiveRangeMask: UIViewRepresentable {
    let totalWidth: CGFloat
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    let height: CGFloat

    func makeUIView(context: Context) -> TimelineInactiveRangeMaskView {
        let view = TimelineInactiveRangeMaskView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TimelineInactiveRangeMaskView, context: Context) {
        // 只有两个独立的覆盖层：左层从轨道左缘延伸到左 bar，右层从右 bar
        // 延伸到轨道右缘。中间选区不画任何像素，始终保持原始亮度。
        let safeLeft = min(max(leftWidth, 0), totalWidth)
        let safeRight = min(max(rightWidth, 0), max(totalWidth - safeLeft, 0))
        view.update(
            totalWidth: totalWidth,
            height: height,
            leftWidth: safeLeft,
            rightWidth: safeRight
        )
    }

    final class TimelineInactiveRangeMaskView: UIView {
        private var totalWidth: CGFloat = 0
        private var maskHeight: CGFloat = 0
        private var leftWidth: CGFloat = 0
        private var rightWidth: CGFloat = 0

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.setFillColor(UIColor.black.withAlphaComponent(0.62).cgColor)
            if leftWidth > 0 {
                context.fill(CGRect(x: 0, y: 0, width: leftWidth, height: maskHeight))
            }
            if rightWidth > 0 {
                context.fill(
                    CGRect(
                        x: totalWidth - rightWidth,
                        y: 0,
                        width: rightWidth,
                        height: maskHeight
                    )
                )
            }
        }

        func update(
            totalWidth: CGFloat,
            height: CGFloat,
            leftWidth: CGFloat,
            rightWidth: CGFloat
        ) {
            self.totalWidth = totalWidth
            maskHeight = height
            self.leftWidth = leftWidth
            self.rightWidth = rightWidth
            isOpaque = false
            contentMode = .redraw
            setNeedsDisplay()
        }
    }
}

/// Cloud Glass 背景修饰：内容层使用系统背景，导航栏和 Tab 栏使用系统材质。
struct MagicBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    LF.background
                    LinearGradient(
                        colors: [
                            LF.brandTint.opacity(0.13),
                            LF.background.opacity(0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                    .ignoresSafeArea()
                }
            }
            .toolbarBackground(.regularMaterial, for: .navigationBar, .tabBar)
    }
}

extension View {
    func magicBackground() -> some View {
        modifier(MagicBackground())
    }

    /// 使用主题第三色渲染导航栏标题，同时保留系统的返回按钮和导航行为。
    func lfNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .lfNavigationTitleToolbar(Text(title))
    }

    /// 本地化标题重载，支持 EditorTool.title 等 LocalizedStringKey。
    func lfNavigationTitle(_ title: LocalizedStringKey) -> some View {
        navigationTitle(title)
            .lfNavigationTitleToolbar(Text(title))
    }

    private func lfNavigationTitleToolbar(_ title: Text) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                title
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(LF.header)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}
