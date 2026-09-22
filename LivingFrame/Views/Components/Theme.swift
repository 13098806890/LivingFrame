import SwiftUI
import UIKit

enum FileSizeText {
    static func string(fromByteCount bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

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
    let timelineText: Color
}

/// 所有已发布的配色方案。每套按界面用途定义背景、表面、操作、品牌强调、文字和时间轴语义色。
enum AppTheme: String, CaseIterable, Identifiable {
    case skyPetal
    case coralNavy
    case limeClover
    case gardenSun
    case appIcon

    var id: String { rawValue }

    /// 旧主题保留在枚举中用于读取旧偏好；当前统一使用从 App 图标提取的配色。
    static let selectableThemes: [AppTheme] = [.appIcon]

    var title: String {
        switch self {
        case .skyPetal: NSLocalizedString("天空花瓣", comment: "Theme name")
        case .coralNavy: NSLocalizedString("珊瑚海", comment: "Theme name")
        case .limeClover: NSLocalizedString("青柠麦田", comment: "Theme name")
        case .gardenSun: NSLocalizedString("花园向日葵", comment: "Theme name")
        case .appIcon: NSLocalizedString("图标配色", comment: "Theme name")
        }
    }

    var subtitle: String {
        switch self {
        case .skyPetal: NSLocalizedString("清透、轻盈、最接近 Liquid Glass", comment: "Theme description")
        case .coralNavy: NSLocalizedString("热情、时尚、对比鲜明", comment: "Theme description")
        case .limeClover: NSLocalizedString("自然、明亮、带一点复古感", comment: "Theme description")
        case .gardenSun: NSLocalizedString("清新、活泼、适合创作场景", comment: "Theme description")
        case .appIcon: NSLocalizedString("晴空蓝、奶油白与珊瑚橙，取自 App 图标", comment: "Theme description")
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
                accent: Color(hex: "47A0C9"),
                destructive: Color(hex: "D6576E"),
                textPrimary: Color(hex: "0E0E0E"),
                textSecondary: Color(hex: "5F707B"),
                timelineClip: Color(hex: "47A0C9"),
                timelineBackground: Color(hex: "95CEE8"),
                timelineSticker: Color(hex: "47A0C9"),
                timelineEffect: Color(hex: "47A0C9"),
                timelineAudio: Color(hex: "95CEE8"),
                timelineText: Color(hex: "47A0C9")
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
                timelineAudio: Color(hex: "00283D"),
                timelineText: Color(hex: "B64B4B")
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
                accent: Color(hex: "4AA112"),
                destructive: Color(hex: "D45050"),
                textPrimary: Color(hex: "1C1A1B"),
                textSecondary: Color(hex: "687066"),
                timelineClip: Color(hex: "4AA112"),
                timelineBackground: Color(hex: "E7F0D6"),
                timelineSticker: Color(hex: "4AA112"),
                timelineEffect: Color(hex: "4AA112"),
                timelineAudio: Color(hex: "4AA112"),
                timelineText: Color(hex: "4AA112")
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
                timelineAudio: Color(hex: "4E8F38"),
                timelineText: Color(hex: "A86D16")
            )
        case .appIcon:
            return ThemePalette(
                background: Color(hex: "F0F8FF"),
                surface: Color(hex: "FFF8EF"),
                surface2: Color(hex: "FBEBD7"),
                actionPrimary: Color(hex: "0875D1"),
                actionDeep: Color(hex: "1357AC"),
                brandTint: Color(hex: "99CFF0"),
                selectionSurface: Color(hex: "DDF0FC"),
                folderIcon: Color(hex: "DE6332"),
                accent: Color(hex: "DE6332"),
                destructive: Color(hex: "C0393D"),
                textPrimary: Color(hex: "18354E"),
                textSecondary: Color(hex: "576C7C"),
                timelineClip: Color(hex: "0875D1"),
                timelineBackground: Color(hex: "99CFF0"),
                timelineSticker: Color(hex: "DE6332"),
                timelineEffect: Color(hex: "DE6332"),
                timelineAudio: Color(hex: "0875D1"),
                timelineText: Color(hex: "DE6332")
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
    static var timelineText: Color { palette.timelineText }

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

enum LFActionButtonKind {
    case primary
    case secondary
    case destructive
}

/// 普通操作按钮按语义归类：推进任务、辅助操作和不可逆操作共享统一尺寸与按压反馈。
struct LFActionButtonStyle: ButtonStyle {
    let kind: LFActionButtonKind

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCompact: Bool {
        controlSize == .mini || controlSize == .small
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary: .white
        case .secondary: LF.selectionText
        case .destructive: LF.destructive
        }
    }

    private var fillStyle: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(LF.accentGradient)
        case .secondary: AnyShapeStyle(LF.surface.opacity(0.94))
        case .destructive: AnyShapeStyle(LF.destructive.opacity(0.09))
        }
    }

    private var strokeColor: Color {
        switch kind {
        case .primary: .clear
        case .secondary: LF.actionPrimary.opacity(0.3)
        case .destructive: LF.destructive.opacity(0.38)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((isCompact ? Font.caption : Font.subheadline).weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, isCompact ? 12 : 16)
            .padding(.vertical, isCompact ? 7 : 10)
            .frame(minHeight: isCompact ? 36 : 44)
            .background {
                RoundedRectangle(cornerRadius: isCompact ? 10 : 12, style: .continuous)
                    .fill(fillStyle)
                    .overlay {
                        RoundedRectangle(cornerRadius: isCompact ? 10 : 12, style: .continuous)
                            .strokeBorder(strokeColor, lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: isCompact ? 10 : 12, style: .continuous))
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// 画布快捷入口与作品卡片共用的圆形主题色图标按钮。
struct LFCircleIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 44
    var iconSize: CGFloat = 18
    var foregroundColor: Color?
    var backgroundColor: Color?

    init(
        diameter: CGFloat = 44,
        iconSize: CGFloat = 18,
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil
    ) {
        self.diameter = diameter
        self.iconSize = iconSize
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(foregroundColor ?? LF.selectionText)
            .frame(width: diameter, height: diameter)
            .background(backgroundColor ?? LF.header.opacity(0.78), in: Circle())
            .shadow(color: (backgroundColor ?? LF.header).opacity(0.22), radius: diameter < 44 ? 5 : 8, y: 3)
            // 小尺寸视觉按钮仍保留 44pt 的可点击区域。
            .frame(width: max(diameter, 44), height: max(diameter, 44))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// 半透明的强调操作：和画布上的添加素材按钮共用主题强调色，同时保持文字清晰。
struct LFTranslucentActionButtonStyle: ButtonStyle {
    var compact = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 13 : 12, style: .continuous)

        configuration.label
            .font(compact ? .system(size: 17, weight: .semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(LF.selectionText)
            .padding(.horizontal, compact ? 0 : 16)
            .frame(minWidth: 44, minHeight: 44)
            .background {
                shape
                    .fill(LF.accentGradient.opacity(0.78))
                    .overlay { shape.strokeBorder(Color.white.opacity(0.34), lineWidth: 1) }
            }
            .contentShape(shape)
            .shadow(color: LF.header.opacity(0.18), radius: 7, y: 3)
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// 顶栏的文字型主操作：浅色玻璃胶囊叠加轻量主题色，文字在所有主题下保持清晰。
struct LFTextPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()

        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LF.selectionText)
            .padding(.horizontal, 14)
            .frame(minWidth: 64, minHeight: 40)
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { shape.fill(LF.header.opacity(0.2)) }
                    .overlay { shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1) }
            }
            .contentShape(shape)
            .shadow(color: LF.header.opacity(0.12), radius: 5, y: 2)
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

extension View {
    func lfActionButtonStyle(_ kind: LFActionButtonKind) -> some View {
        buttonStyle(LFActionButtonStyle(kind: kind))
    }

    func lfCircleIconButtonStyle(
        diameter: CGFloat = 44,
        iconSize: CGFloat = 18,
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil
    ) -> some View {
        buttonStyle(LFCircleIconButtonStyle(
            diameter: diameter,
            iconSize: iconSize,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor
        ))
    }

    func lfTranslucentActionButtonStyle(compact: Bool = false) -> some View {
        buttonStyle(LFTranslucentActionButtonStyle(compact: compact))
    }

    func lfTextPillButtonStyle() -> some View {
        buttonStyle(LFTextPillButtonStyle())
    }
}

struct SectionCard<Content: View>: View {
    let title: Text?
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey?, @ViewBuilder content: () -> Content) {
        self.title = title.map { Text($0) }
        self.content = content()
    }

    init(verbatimTitle: String, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: verbatimTitle)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                title
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
    let title: LocalizedStringKey
    let message: LocalizedStringKey

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
    /// 未选中轨道也要保留源范围信息，但视觉强度低于当前选中轨道。
    var opacity: CGFloat = 0.62

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
            rightWidth: safeRight,
            opacity: min(max(opacity, 0), 1)
        )
    }

    final class TimelineInactiveRangeMaskView: UIView {
        private var totalWidth: CGFloat = 0
        private var maskHeight: CGFloat = 0
        private var leftWidth: CGFloat = 0
        private var rightWidth: CGFloat = 0
        private var maskOpacity: CGFloat = 0.62

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.setFillColor(UIColor.black.withAlphaComponent(maskOpacity).cgColor)
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
            rightWidth: CGFloat,
            opacity: CGFloat
        ) {
            self.totalWidth = totalWidth
            maskHeight = height
            self.leftWidth = leftWidth
            self.rightWidth = rightWidth
            maskOpacity = opacity
            isOpaque = false
            contentMode = .redraw
            setNeedsDisplay()
        }
    }
}

/// Cloud Glass 背景修饰：主题背景覆盖整个安全区域，导航栏与主体背景连续，Tab 栏保持稳定底色。
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
                }
                .ignoresSafeArea()
            }
            // 导航栏和 Tab 栏都直接使用页面背景，不绘制系统材质边界线。
            .toolbarBackground(.hidden, for: .navigationBar, .tabBar)
            .toolbarColorScheme(.light, for: .navigationBar, .tabBar)
    }
}

extension View {
    func magicBackground() -> some View {
        modifier(MagicBackground())
    }

    /// 使用统一的高对比度主文字色渲染导航栏标题，同时保留系统的返回按钮和导航行为。
    func lfNavigationTitle(verbatim title: String) -> some View {
        navigationTitle(Text(verbatim: title))
            .lfNavigationTitleToolbar(Text(verbatim: title))
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
                    .foregroundStyle(LF.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}
