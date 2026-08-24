import CoreGraphics
import Foundation

enum PaperFoldCorner: String, Sendable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft
}

/// 组合撕边、纸纹、接触阴影和卷角的通用纸张效果。
///
/// 该类型不依赖 Composition、背景分区或 UI 枚举，可直接复用于贴纸、
/// 相框、素材卡片以及后续的画布主题。静态画布效果按参数缓存。
enum PaperEffectRenderer {
    private static let overlayCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 12
        return cache
    }()

    private static func tornOpeningPath(_ rect: CGRect, profile: TornEdgeProfile) -> CGPath {
        let path = CGMutablePath()
        TornEdgeGeometry.addRect(rect, profile: profile, in: path)
        return path
    }

    static func borderOverlay(
        size: CGSize,
        profile: TornEdgeProfile,
        borderInset: CGFloat,
        foldedCorner: PaperFoldCorner? = nil
    ) -> CGImage? {
        let safeInset = max(borderInset, 1)
        let cornerKey = foldedCorner?.rawValue ?? "none"
        let key = "paper-overlay-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))-\(profile.rawValue)-\(Int((safeInset * 100).rounded()))-\(cornerKey)" as NSString
        if let cached = overlayCache.object(forKey: key) { return cached }

        if let assetImage = PaperAssetRenderer.borderOverlay(
            size: size,
            profile: profile,
            borderInset: safeInset,
            foldedCorner: foldedCorner
        ) {
            overlayCache.setObject(assetImage, forKey: key)
            return assetImage
        }

        if let nativeImage = NativePaperEffectRenderer.canvasOverlay(
            size: size,
            profile: profile,
            inset: safeInset
        ) {
            let image = foldedCorner.map { corner in
                ProceduralRasterRenderer.makeImage(size: size) { context, rect in
                    context.draw(nativeImage, in: rect)
                    let openingPath = tornOpeningPath(rect.insetBy(dx: safeInset, dy: safeInset), profile: profile)
                    drawOpeningEdge(in: context, path: openingPath, inset: safeInset, profile: profile)
                    drawFoldedCorner(in: context, canvas: rect, inset: safeInset, corner: corner)
                }
            } ?? ProceduralRasterRenderer.makeImage(size: size) { context, rect in
                context.draw(nativeImage, in: rect)
                let openingPath = tornOpeningPath(rect.insetBy(dx: safeInset, dy: safeInset), profile: profile)
                drawOpeningEdge(in: context, path: openingPath, inset: safeInset, profile: profile)
            }
            if let image { overlayCache.setObject(image, forKey: key) }
            return image
        }

        let image = ProceduralRasterRenderer.makeImage(size: size) { context, rect in
            let openingRect = rect.insetBy(dx: safeInset, dy: safeInset)
            let openingPath = CGMutablePath()
            TornEdgeGeometry.addRect(openingRect, profile: profile, in: openingPath)

            context.addRect(rect)
            context.addPath(openingPath)
            context.setFillColor(CGColor(red: 0.985, green: 0.978, blue: 0.95, alpha: 0.98))
            context.drawPath(using: .eoFill)

            PaperTextureRenderer.drawGrain(
                in: context,
                bounds: rect,
                excluding: openingPath
            )
            drawOpeningEdge(
                in: context,
                path: openingPath,
                inset: safeInset,
                profile: profile
            )

            if let foldedCorner {
                drawFoldedCorner(
                    in: context,
                    canvas: rect,
                    inset: safeInset,
                    corner: foldedCorner
                )
            }
        }
        if let image { overlayCache.setObject(image, forKey: key) }
        return image
    }

    /// 给任意已有轮廓增加纸边与接触阴影。
    static func drawTornEdge(
        in context: CGContext,
        path: CGPath,
        referenceLength: CGFloat,
        profile: TornEdgeProfile
    ) {
        let isLayered = profile == .layered
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: referenceLength * 0.002, height: -referenceLength * 0.003),
            blur: referenceLength * (isLayered ? 0.007 : 0.004),
            color: CGColor(gray: 0.12, alpha: isLayered ? 0.28 : 0.18)
        )
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setStrokeColor(CGColor(red: 0.97, green: 0.95, blue: 0.89, alpha: 0.92))
        context.setLineWidth(referenceLength * (isLayered ? 0.012 : 0.006))
        context.strokePath()
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(CGColor(red: 1, green: 0.99, blue: 0.95, alpha: 0.78))
        context.setLineWidth(referenceLength * (isLayered ? 0.004 : 0.0025))
        context.strokePath()
    }

    private static func drawOpeningEdge(
        in context: CGContext,
        path: CGPath,
        inset: CGFloat,
        profile: TornEdgeProfile
    ) {
        let isLayered = profile == .layered
        context.saveGState()
        // 阴影只允许进入照片开口，纸面一侧保持干净。
        context.addPath(path)
        context.clip()
        context.setLineJoin(.round)
        context.setLineCap(.round)

        // 接触阴影要落在照片上，而不是被粗白描边盖住。
        context.addPath(path)
        context.setStrokeColor(CGColor(
            red: 0.12,
            green: 0.10,
            blue: 0.08,
            alpha: isLayered ? 0.30 : 0.20
        ))
        context.setLineWidth(max(inset * 0.050, 2.5))
        context.strokePath()

        context.setShadow(
            offset: CGSize(width: inset * 0.018, height: -inset * 0.022),
            blur: inset * (isLayered ? 0.20 : 0.14),
            color: CGColor(gray: 0.03, alpha: isLayered ? 0.48 : 0.30)
        )
        context.addPath(path)
        context.setStrokeColor(CGColor(red: 0.28, green: 0.25, blue: 0.20, alpha: 0.10))
        context.setLineWidth(max(inset * 0.055, 2.5))
        context.strokePath()
        context.restoreGState()

        // 只留一条很窄的纸纤维高光，避免形成白色软管。
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setStrokeColor(CGColor(red: 1, green: 0.995, blue: 0.96, alpha: 0.86))
        context.setLineWidth(max(inset * 0.025, 1.25))
        context.strokePath()

        if profile != .soft {
            context.addPath(path)
            context.setLineDash(phase: 0.4, lengths: [0.8, 2.2, 1.4, 3.1])
            context.setStrokeColor(CGColor(red: 0.50, green: 0.44, blue: 0.34, alpha: 0.40))
            context.setLineWidth(max(inset * 0.010, 0.8))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }
    }

    /// 静态卷角：用一个有弧度的三角折面表达 dog-ear，避免把透明照片开口
    /// 交给 CIPageCurl 后产生整页翻起。它仍然是原生 Core Graphics，并与
    /// 纸边一起缓存，因此不会进入播放的逐帧渲染路径。
    private static func drawFoldedCorner(
        in context: CGContext,
        canvas: CGRect,
        inset: CGFloat,
        corner: PaperFoldCorner
    ) {
        let fold = min(max(inset * 1.75, 60), min(canvas.width, canvas.height) * 0.18)
        let isRight = corner == .bottomRight || corner == .topRight
        let isTop = corner == .topRight || corner == .topLeft
        let outerX = isRight ? canvas.maxX : canvas.minX
        let outerY = isTop ? canvas.maxY : canvas.minY
        func point(inwardX: CGFloat, inwardY: CGFloat) -> CGPoint {
            CGPoint(
                x: outerX + (isRight ? -inwardX : inwardX),
                y: outerY + (isTop ? -inwardY : inwardY)
            )
        }

        let outerCorner = point(inwardX: 1, inwardY: 1)
        let rootA = point(inwardX: fold, inwardY: 0)
        let rootB = point(inwardX: 0, inwardY: fold)
        // The front face is slightly smaller than the dark underside. Leaving
        // this narrow reveal at the two outer edges is what makes the corner
        // look lifted instead of looking like a flat outlined triangle.
        let frontA = point(inwardX: fold * 0.82, inwardY: fold * 0.055)
        let frontB = point(inwardX: fold * 0.055, inwardY: fold * 0.82)
        let creaseControl = point(inwardX: fold * 0.56, inwardY: fold * 0.56)

        let underPath = CGMutablePath()
        underPath.move(to: outerCorner)
        underPath.addLine(to: rootA)
        underPath.addQuadCurve(to: rootB, control: creaseControl)
        underPath.closeSubpath()
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: isRight ? -fold * 0.06 : fold * 0.06, height: isTop ? -fold * 0.06 : fold * 0.06),
            blur: fold * 0.12,
            color: CGColor(gray: 0.02, alpha: 0.40)
        )
        context.addPath(underPath)
        context.setFillColor(CGColor(red: 0.30, green: 0.29, blue: 0.27, alpha: 0.70))
        context.fillPath()
        context.restoreGState()

        let foldPath = CGMutablePath()
        foldPath.move(to: outerCorner)
        foldPath.addLine(to: frontA)
        foldPath.addQuadCurve(to: frontB, control: creaseControl)
        foldPath.closeSubpath()

        context.saveGState()
        context.addPath(foldPath)
        context.clip()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(
                  colorsSpace: colorSpace,
                  colors: [
                      CGColor(red: 0.48, green: 0.46, blue: 0.42, alpha: 0.98),
                      CGColor(red: 0.86, green: 0.84, blue: 0.78, alpha: 0.99),
                      CGColor(red: 1.0, green: 0.995, blue: 0.96, alpha: 1)
                  ] as CFArray,
                  locations: [0, 0.46, 1]
              ) else {
            context.restoreGState()
            return
        }
        context.drawLinearGradient(gradient, start: creaseControl, end: outerCorner, options: [])
        PaperTextureRenderer.drawGrain(in: context, bounds: foldPath.boundingBoxOfPath, style: .foldedBack)
        context.restoreGState()

        // 弯曲折痕：暗线在底部，窄高光紧贴其上，形成纸张厚度。
        context.saveGState()
        context.addPath(foldPath)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setStrokeColor(CGColor(red: 0.22, green: 0.20, blue: 0.17, alpha: 0.58))
        context.setLineWidth(max(fold * 0.026, 2))
        context.strokePath()
        context.restoreGState()

        let creasePath = CGMutablePath()
        creasePath.move(to: frontA)
        creasePath.addQuadCurve(to: frontB, control: creaseControl)
        context.saveGState()
        context.addPath(creasePath)
        context.setShadow(offset: .zero, blur: fold * 0.04, color: CGColor(gray: 0.02, alpha: 0.44))
        context.setStrokeColor(CGColor(red: 0.20, green: 0.18, blue: 0.15, alpha: 0.72))
        context.setLineWidth(max(fold * 0.035, 2.5))
        context.strokePath()
        context.restoreGState()
        context.addPath(creasePath)
        context.setStrokeColor(CGColor(red: 1, green: 0.99, blue: 0.95, alpha: 0.72))
        context.setLineWidth(max(fold * 0.010, 1))
        context.strokePath()
    }
}
