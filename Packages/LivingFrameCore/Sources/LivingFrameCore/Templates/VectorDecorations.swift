import CoreGraphics
import CoreImage
import Foundation

/// 矢量装饰绘制：CoreGraphics 代码生成，体积 0、无限缩放、双平台复用
public struct DecorationRenderer {
    private let cache = NSCache<NSString, CIImage>()

    public init() {}

    /// 装饰 id 约定（与 TemplateCatalog 一致）：
    /// frame-gold / corners / vignette / glow-soft / glow-orb / dust / wand-beam
    public func image(for decorationID: String, canvas: CGRect) -> CIImage? {
        let key = "\(decorationID)-\(Int(canvas.width))x\(Int(canvas.height))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let cg = draw(decorationID: decorationID, size: canvas.size) else { return nil }
        let ci = CIImage(cgImage: cg)
        cache.setObject(ci, forKey: key)
        return ci
    }

    private func draw(decorationID: String, size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        switch decorationID {
        case "frame-gold":
            drawFrame(ctx, size: size)
        case "corners":
            drawCorners(ctx, size: size)
        case "vignette":
            drawVignette(ctx, size: size)
        case "glow-soft":
            drawGlow(ctx, size: size, soft: true)
        case "glow-orb":
            drawGlow(ctx, size: size, soft: false)
        case "dust":
            drawDust(ctx, size: size)
        case "wand-beam":
            drawWandBeam(ctx, size: size)
        default:
            return nil
        }
        return ctx.makeImage()
    }

    // MARK: - 画框

    private func drawFrame(_ ctx: CGContext, size: CGSize) {
        let gold = CGColor(red: 0.87, green: 0.72, blue: 0.38, alpha: 1)
        let goldDeep = CGColor(red: 0.55, green: 0.42, blue: 0.18, alpha: 1)
        let frameW = min(size.width, size.height) * 0.045
        let rect = CGRect(x: frameW / 2, y: frameW / 2, width: size.width - frameW, height: size.height - frameW)

        ctx.setLineWidth(frameW)
        ctx.setStrokeColor(goldDeep)
        ctx.stroke(rect.insetBy(dx: frameW * 0.35, dy: frameW * 0.35))
        ctx.setStrokeColor(gold)
        ctx.stroke(rect)
        // 内侧细金线
        ctx.setLineWidth(frameW * 0.25)
        ctx.setStrokeColor(gold)
        ctx.stroke(rect.insetBy(dx: frameW * 0.75, dy: frameW * 0.75))
    }

    private func drawCorners(_ ctx: CGContext, size: CGSize) {
        let gold = CGColor(red: 0.87, green: 0.72, blue: 0.38, alpha: 1)
        let arm = min(size.width, size.height) * 0.16
        let inset = min(size.width, size.height) * 0.045
        let width: CGFloat = min(size.width, size.height) * 0.02
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(gold)
        let points: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: inset, y: size.height - inset), CGPoint(x: inset + arm, y: size.height - inset),
             CGPoint(x: inset, y: size.height - inset), CGPoint(x: inset, y: size.height - inset - arm)),
            (CGPoint(x: size.width - inset, y: size.height - inset), CGPoint(x: size.width - inset - arm, y: size.height - inset),
             CGPoint(x: size.width - inset, y: size.height - inset), CGPoint(x: size.width - inset, y: size.height - inset - arm)),
            (CGPoint(x: inset, y: inset), CGPoint(x: inset + arm, y: inset),
             CGPoint(x: inset, y: inset), CGPoint(x: inset, y: inset + arm)),
            (CGPoint(x: size.width - inset, y: inset), CGPoint(x: size.width - inset - arm, y: inset),
             CGPoint(x: size.width - inset, y: inset), CGPoint(x: size.width - inset, y: inset + arm))
        ]
        for (h1, h2, v1, v2) in points {
            ctx.move(to: h1); ctx.addLine(to: h2)
            ctx.move(to: v1); ctx.addLine(to: v2)
        }
        ctx.strokePath()
    }

    // MARK: - 暗角

    private func drawVignette(_ ctx: CGContext, size: CGSize) {
        let colors = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.45),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.72]
        ) else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.72
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: radius * 0.35, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: - 光效

    private func drawGlow(_ ctx: CGContext, size: CGSize, soft: Bool) {
        let colors = [
            CGColor(red: 1.0, green: 0.92, blue: 0.62, alpha: 0.9),
            CGColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 0.18),
            CGColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 0)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.45, 1]
        ) else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * (soft ? 0.55 : 0.3)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: - 飘尘

    private func drawDust(_ ctx: CGContext, size: CGSize) {
        var generator = SystemRandomNumberGenerator()
        let count = 60
        for _ in 0..<count {
            let x = CGFloat.random(in: 0...size.width, using: &generator)
            let y = CGFloat.random(in: 0...size.height, using: &generator)
            let r = CGFloat.random(in: 0.5...2.2, using: &generator)
            let alpha = CGFloat.random(in: 0.12...0.5, using: &generator)
            ctx.setFillColor(CGColor(red: 1, green: 0.94, blue: 0.75, alpha: alpha))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - 魔杖光束

    private func drawWandBeam(_ ctx: CGContext, size: CGSize) {
        // 右上角斜向金色光束
        ctx.saveGState()
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: -CGFloat.pi / 5)
        let colors = [
            CGColor(red: 1, green: 0.92, blue: 0.62, alpha: 0.55),
            CGColor(red: 1, green: 0.92, blue: 0.62, alpha: 0)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) else { return }
        let beamRect = CGRect(x: -size.width * 0.45, y: -4, width: size.width * 0.9, height: 8)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: beamRect.minX, y: 0),
            end: CGPoint(x: beamRect.maxX, y: 0),
            options: []
        )
        ctx.restoreGState()
        // 中心星芒点
        let sparkleColors = [
            CGColor(red: 1, green: 1, blue: 0.85, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0.85, alpha: 0)
        ] as CFArray
        if let sparkle = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sparkleColors, locations: [0, 1]) {
            ctx.drawRadialGradient(
                sparkle, startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: min(size.width, size.height) * 0.12,
                options: []
            )
        }
        ctx.restoreGState()
    }
}
