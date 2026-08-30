import CoreGraphics
import CoreText
import Foundation

/// 文字排版的唯一尺寸来源。
///
/// 预览选中框和最终渲染都使用 CoreText 的实际字形边界，避免一个地方用
/// “字符数估算”、另一个地方用 CoreText 渲染而产生框短、顶部留白等偏差。
public enum TextLayout {
    private struct Layout {
        let frame: CTFrame
        let inkBounds: CGRect
        let padding: CGFloat
    }

    /// 返回包含少量触控安全边距的实际字形尺寸。
    public static func measuredSize(for text: TextElement, maxWidth: CGFloat) -> CGSize {
        guard let layout = makeLayout(for: text, maxWidth: maxWidth) else {
            return CGSize(width: 1, height: 1)
        }
        let width = max(1, ceil(layout.inkBounds.width + layout.padding * 2))
        let height = max(1, ceil(layout.inkBounds.height + layout.padding * 2))
        return CGSize(width: width, height: height)
    }

    /// 将文字绘制到紧贴字形边界的透明位图中。
    public static func draw(
        _ text: TextElement,
        in context: CGContext,
        maxWidth: CGFloat,
        size: CGSize
    ) {
        guard let layout = makeLayout(for: text, maxWidth: maxWidth) else { return }

        let dx = layout.padding - layout.inkBounds.minX
        let dy = layout.padding - layout.inkBounds.minY

        context.saveGState()
        // CGBitmapContext 本身已经是 CoreText 所需的 y-up 坐标系；直接绘制，
        // 不再额外叠加 180° 旋转和左右镜像。此前这组变换与 CI/UIImage 的
        // 后续坐标转换叠加，导致最终文字同时被镜像和旋转。
        context.translateBy(x: dx, y: dy)
        CTFrameDraw(layout.frame, context)
        context.restoreGState()
    }

    private static func makeLayout(for text: TextElement, maxWidth: CGFloat) -> Layout? {
        let font = CTFontCreateWithName(
            (text.fontName ?? "HelveticaNeue-Bold") as CFString,
            max(text.fontSize, 1),
            nil
        )
        let components = text.colorHex.hexComponents()
        let color = CGColor(
            red: components.r,
            green: components.g,
            blue: components.b,
            alpha: 1
        )
        let attributed = NSAttributedString(string: text.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraintWidth = max(maxWidth.isFinite ? maxWidth : 1, 1)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(),
            nil,
            CGSize(width: constraintWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let frameHeight = max(ceil(suggested.height), ceil(text.fontSize * 1.5), 1)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: constraintWidth, height: frameHeight),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else {
            let fallback = CGRect(x: 0, y: 0, width: max(suggested.width, 1), height: max(suggested.height, 1))
            return Layout(frame: frame, inkBounds: fallback, padding: max(2, ceil(text.fontSize * 0.04)))
        }

        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        var inkBounds = CGRect.null
        for (line, origin) in zip(lines, origins) {
            var lineBounds = CTLineGetImageBounds(line, nil)
            if lineBounds.isNull || lineBounds.isEmpty {
                lineBounds = CTLineGetBoundsWithOptions(line, [])
            }
            inkBounds = inkBounds.union(lineBounds.offsetBy(dx: origin.x, dy: origin.y))
        }
        guard !inkBounds.isNull, inkBounds.width.isFinite, inkBounds.height.isFinite else {
            return nil
        }
        return Layout(
            frame: frame,
            inkBounds: inkBounds,
            padding: max(2, ceil(text.fontSize * 0.04))
        )
    }
}

extension String {
    /// hex 颜色字符串拆分为 RGB 分量；非法输入回退为中灰。
    /// 文字排版和其它 Core 渲染器共用这一解析逻辑。
    func hexComponents() -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var hex = trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard hex.count == 6, Scanner(string: hex).scanHexInt64(&value) else {
            return (0.5, 0.5, 0.5)
        }
        return (
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
    }
}
