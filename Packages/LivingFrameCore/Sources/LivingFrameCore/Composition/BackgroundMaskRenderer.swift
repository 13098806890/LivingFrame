import CoreGraphics
import Foundation

/// 背景图片元素的区域遮罩与边缘绘制。
/// 遮罩在元素自己的局部坐标中生成，因此图片整体移动/缩放/旋转时边缘不会抖动。
enum BackgroundMaskRenderer {
    private static let maskCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 12
        return cache
    }()
    private static let edgeCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 12
        return cache
    }()
    /// 画布级手撕相纸叠层。图像内容仍铺满画布，只由最上层纸边覆盖外沿，
    /// 不会改变任意元素的 transform、时间轴或分区位置。
    static func canvasEdgeImage(
        size: CGSize,
        style: CanvasEdgeStyle,
        width: CanvasEdgeWidth
    ) -> CGImage? {
        guard style != .none else { return nil }
        let profile: TornEdgeProfile
        let baseInset: CGFloat
        let shortSide = min(size.width, size.height)
        switch style {
        case .none:
            return nil
        case .tornSoft:
            profile = .soft
            baseInset = min(max(shortSide * 0.032, 18), 48)
        case .tornFibrous:
            profile = .fibrous
            baseInset = min(max(shortSide * 0.040, 24), 64)
        case .tornLayered:
            profile = .layered
            baseInset = min(max(shortSide * 0.046, 28), 76)
        }
        let widthMultiplier: CGFloat
        switch width {
        case .narrow: widthMultiplier = 0.72
        case .standard: widthMultiplier = 1
        case .wide: widthMultiplier = 1.45
        }
        return PaperEffectRenderer.borderOverlay(
            size: size,
            profile: profile,
            borderInset: baseInset * widthMultiplier,
            foldedCorner: style == .tornLayered ? .bottomRight : nil
        )
    }

    static func regionRect(_ region: BackgroundRegion, in canvas: CGRect) -> CGRect {
        switch region {
        case .full, .diagonal:
            return canvas
        case .upperHalf:
            return CGRect(x: canvas.minX, y: canvas.midY, width: canvas.width, height: canvas.height / 2)
        case .lowerHalf:
            return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: canvas.height / 2)
        case .quarter:
            return CGRect(x: canvas.midX, y: canvas.midY, width: canvas.width / 2, height: canvas.height / 2)
        }
    }

    static func maskImage(
        size: CGSize,
        region: BackgroundRegion,
        edgeStyle: BackgroundEdgeStyle
    ) -> CGImage? {
        maskImage(
            size: size,
            settings: BackgroundElementSettings(region: region, edgeStyle: edgeStyle)
        )
    }

    static func maskImage(
        size: CGSize,
        settings: BackgroundElementSettings
    ) -> CGImage? {
        let key = cacheKey(prefix: "mask", size: size, settings: settings)
        if let cached = maskCache.object(forKey: key) { return cached }
        let image = ProceduralRasterRenderer.makeImage(size: size) { context, rect in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(path(for: settings, in: rect))
            context.fillPath()
        }
        if let image { maskCache.setObject(image, forKey: key) }
        return image
    }

    static func edgeImage(
        size: CGSize,
        region: BackgroundRegion,
        edgeStyle: BackgroundEdgeStyle
    ) -> CGImage? {
        edgeImage(
            size: size,
            settings: BackgroundElementSettings(region: region, edgeStyle: edgeStyle)
        )
    }

    static func edgeImage(
        size: CGSize,
        settings: BackgroundElementSettings
    ) -> CGImage? {
        guard settings.edgeStyle == .comic || tornProfile(for: settings.edgeStyle) != nil else { return nil }
        let key = cacheKey(prefix: "edge", size: size, settings: settings)
        if let cached = edgeCache.object(forKey: key) { return cached }
        if let profile = tornProfile(for: settings.edgeStyle),
           let nativeImage = NativePaperEffectRenderer.tornEdgeOverlay(
               size: size,
               path: path(for: settings, in: CGRect(origin: .zero, size: size)),
               profile: profile
           ) {
            edgeCache.setObject(nativeImage, forKey: key)
            return nativeImage
        }
        let image = ProceduralRasterRenderer.makeImage(size: size) { context, rect in
            if settings.edgeStyle == .comic {
                var edgeSettings = settings
                edgeSettings.edgeStyle = .flat
                let path = path(for: edgeSettings, in: rect)
                context.addPath(path)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
                context.setLineWidth(max(rect.width, rect.height) * 0.012)
                context.strokePath()

                context.addPath(path)
                context.setStrokeColor(CGColor(gray: 0.05, alpha: 0.95))
                context.setLineWidth(max(rect.width, rect.height) * 0.005)
                context.strokePath()
            } else {
                let path = path(for: settings, in: rect)
                if let profile = tornProfile(for: settings.edgeStyle) {
                    PaperEffectRenderer.drawTornEdge(
                        in: context,
                        path: path,
                        referenceLength: max(rect.width, rect.height),
                        profile: profile
                    )
                }
            }
        }
        if let image { edgeCache.setObject(image, forKey: key) }
        return image
    }

    private static func path(
        for settings: BackgroundElementSettings,
        in rect: CGRect
    ) -> CGPath {
        guard settings.splitCount != .full else {
            return path(for: settings.region, in: rect, edgeStyle: settings.edgeStyle)
        }

        let angle = normalizedAngle(settings.dividerAngle)
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        // SwiftUI 预览使用屏幕坐标（y 向下），这里反转法线方向，
        // 让预览中点击的分区与最终 Core Image 渲染保持一致。
        let normal = CGPoint(x: direction.y, y: -direction.x)
        let partition = max(
            0,
            min(
                settings.selectedPartition,
                settings.splitCount == .two ? 1 : 3
            )
        )

        if settings.splitCount == .two {
            let sign: CGFloat = partition == 0 ? 1 : -1
            let center = insetDividerCenter(
                BackgroundDividerGeometry.center(
                    in: rect,
                    normal: normal,
                    offset: settings.primaryDividerOffset
                ),
                normal: normal,
                sign: sign,
                edgeStyle: settings.edgeStyle,
                in: rect
            )
            return clippedPath(
                in: rect,
                center: center,
                normal: normal,
                sign: sign
            )
        }

        // 4 区由两条互相垂直、可独立平移的分割线组成。
        // 分区编号按 (+,+)、(-,+)、(-,-)、(+,-) 排列。
        let secondNormal = CGPoint(x: -direction.x, y: -direction.y)
        let firstSign: CGFloat = partition == 0 || partition == 3 ? 1 : -1
        let secondSign: CGFloat = partition == 0 || partition == 1 ? 1 : -1
        let firstCenter = insetDividerCenter(BackgroundDividerGeometry.center(
            in: rect,
            normal: normal,
            offset: settings.primaryDividerOffset
        ), normal: normal, sign: firstSign, edgeStyle: settings.edgeStyle, in: rect)
        let secondCenter = insetDividerCenter(BackgroundDividerGeometry.center(
            in: rect,
            normal: secondNormal,
            offset: settings.secondaryDividerOffset
        ), normal: secondNormal, sign: secondSign, edgeStyle: settings.edgeStyle, in: rect)
        return clippedPath(
            clippedPolygon(
                rectanglePolygon(rect),
                center: firstCenter,
                normal: normal,
                sign: firstSign
            ),
            center: secondCenter,
            normal: secondNormal,
            sign: secondSign
        )
    }

    private static func normalizedAngle(_ degrees: CGFloat) -> CGFloat {
        let safe = degrees.isFinite ? degrees : 90
        let normalized = safe.truncatingRemainder(dividingBy: 180)
        return (normalized < 0 ? normalized + 180 : normalized) * .pi / 180
    }

    /// 分割边缘只向素材自身一侧后退；两张相邻素材都选择手撕时，留白自然加宽。
    private static func insetDividerCenter(
        _ center: CGPoint,
        normal: CGPoint,
        sign: CGFloat,
        edgeStyle: BackgroundEdgeStyle,
        in rect: CGRect
    ) -> CGPoint {
        guard tornProfile(for: edgeStyle) != nil else { return center }
        let inset = min(max(min(rect.width, rect.height) * 0.012, 5), 16)
        return CGPoint(
            x: center.x + normal.x * sign * inset,
            y: center.y + normal.y * sign * inset
        )
    }

    private static func rectanglePolygon(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private static func clippedPath(
        in rect: CGRect,
        center: CGPoint,
        normal: CGPoint,
        sign: CGFloat
    ) -> CGPath {
        clippedPath(
            rectanglePolygon(rect),
            center: center,
            normal: normal,
            sign: sign
        )
    }

    private static func clippedPath(
        _ polygon: [CGPoint],
        center: CGPoint,
        normal: CGPoint,
        sign: CGFloat
    ) -> CGPath {
        let clipped = clippedPolygon(
            polygon,
            center: center,
            normal: normal,
            sign: sign
        )
        let path = CGMutablePath()
        guard let first = clipped.first else { return path }
        path.move(to: first)
        for point in clipped.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// Sutherland-Hodgman 裁剪：保留分割线一侧的多边形区域。
    private static func clippedPolygon(
        _ polygon: [CGPoint],
        center: CGPoint,
        normal: CGPoint,
        sign: CGFloat
    ) -> [CGPoint] {
        guard !polygon.isEmpty else { return [] }
        var result: [CGPoint] = []
        for index in polygon.indices {
            let current = polygon[index]
            let previous = polygon[(index + polygon.count - 1) % polygon.count]
            let currentValue = signedDistance(current, center: center, normal: normal, sign: sign)
            let previousValue = signedDistance(previous, center: center, normal: normal, sign: sign)
            let currentInside = currentValue >= 0
            let previousInside = previousValue >= 0

            if currentInside != previousInside {
                let denominator = previousValue - currentValue
                let progress = abs(denominator) > 0.0001 ? previousValue / denominator : 0
                result.append(CGPoint(
                    x: previous.x + (current.x - previous.x) * progress,
                    y: previous.y + (current.y - previous.y) * progress
                ))
            }
            if currentInside {
                result.append(current)
            }
        }
        return result
    }

    private static func signedDistance(
        _ point: CGPoint,
        center: CGPoint,
        normal: CGPoint,
        sign: CGFloat
    ) -> CGFloat {
        ((point.x - center.x) * normal.x + (point.y - center.y) * normal.y) * sign
    }

    private static func path(
        for region: BackgroundRegion,
        in rect: CGRect,
        edgeStyle: BackgroundEdgeStyle
    ) -> CGPath {
        let path = CGMutablePath()
        let left = rect.minX
        let right = rect.maxX
        let bottom = rect.minY
        let top = rect.maxY

        switch region {
        case .full:
            path.addRect(rect)
        case .quarter:
            let quarterRect = CGRect(
                x: rect.midX,
                y: rect.midY,
                width: rect.width / 2,
                height: rect.height / 2
            )
            path.addRect(quarterRect)
        case .diagonal:
            path.move(to: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: right, y: top))
            if edgeStyle == .zigzag {
                addZigzag(from: CGPoint(x: right, y: bottom), to: CGPoint(x: left, y: top), in: path)
            } else if let profile = tornProfile(for: edgeStyle) {
                TornEdgeGeometry.addLine(
                    from: CGPoint(x: right, y: bottom),
                    to: CGPoint(x: left, y: top),
                    profile: profile,
                    in: path
                )
            } else {
                path.addLine(to: CGPoint(x: right, y: bottom))
                path.addLine(to: CGPoint(x: left, y: top))
            }
            path.closeSubpath()
        case .upperHalf:
            path.move(to: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: right, y: top))
            path.addLine(to: CGPoint(x: right, y: rect.midY))
            addHorizontalBoundary(
                from: right,
                to: left,
                baseline: rect.midY,
                in: rect,
                edgeStyle: edgeStyle,
                path: path
            )
            path.closeSubpath()
        case .lowerHalf:
            path.move(to: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: right, y: bottom))
            path.addLine(to: CGPoint(x: right, y: rect.midY))
            addHorizontalBoundary(
                from: right,
                to: left,
                baseline: rect.midY,
                in: rect,
                edgeStyle: edgeStyle,
                path: path
            )
            path.closeSubpath()
        }
        return path
    }

    private static func cacheKey(
        prefix: String,
        size: CGSize,
        region: BackgroundRegion,
        edgeStyle: BackgroundEdgeStyle
    ) -> NSString {
        "\(prefix)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))-\(region.rawValue)-\(edgeStyle.rawValue)" as NSString
    }

    private static func cacheKey(
        prefix: String,
        size: CGSize,
        settings: BackgroundElementSettings
    ) -> NSString {
        let angle = Int(settings.dividerAngle.isFinite ? settings.dividerAngle.rounded() : 90)
        let primaryOffset = Int((settings.primaryDividerOffset * 1_000).rounded())
        let secondaryOffset = Int((settings.secondaryDividerOffset * 1_000).rounded())
        return "\(prefix)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))-\(settings.region.rawValue)-\(settings.edgeStyle.rawValue)-\(settings.splitCount.rawValue)-\(angle)-\(primaryOffset)-\(secondaryOffset)-\(settings.selectedPartition)" as NSString
    }

    private static func addHorizontalBoundary(
        from start: CGFloat,
        to end: CGFloat,
        baseline: CGFloat,
        in rect: CGRect,
        edgeStyle: BackgroundEdgeStyle,
        path: CGMutablePath
    ) {
        guard edgeStyle != .flat && edgeStyle != .comic else {
            path.addLine(to: CGPoint(x: end, y: baseline))
            return
        }
        if edgeStyle == .zigzag {
            let step: CGFloat = 28
            let count = max(Int(abs(start - end) / step), 1)
            for index in 1...count {
                let progress = CGFloat(index) / CGFloat(count)
                let x = start + (end - start) * progress
                let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                let y = baseline + direction * min(rect.height * 0.045, 18)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            return
        }

        guard let profile = tornProfile(for: edgeStyle) else {
            path.addLine(to: CGPoint(x: end, y: baseline))
            return
        }
        let count = max(Int(abs(start - end) / 13), 18)
        for index in 1...count {
            let progress = CGFloat(index) / CGFloat(count)
            let x = start + (end - start) * progress
            path.addLine(to: CGPoint(
                x: x,
                y: baseline + TornEdgeGeometry.offset(
                    progress: progress,
                    profile: profile,
                    limit: rect.height
                )
            ))
        }
    }

    private static func tornProfile(for edgeStyle: BackgroundEdgeStyle) -> TornEdgeProfile? {
        switch edgeStyle {
        case .torn: return .soft
        case .tornFibrous: return .fibrous
        case .tornLayered: return .layered
        case .flat, .comic, .zigzag: return nil
        }
    }

    private static func addZigzag(from start: CGPoint, to end: CGPoint, in path: CGMutablePath) {
        let count = 18
        let normal = CGPoint(x: -(end.y - start.y), y: end.x - start.x)
        let length = max(sqrt(normal.x * normal.x + normal.y * normal.y), 1)
        for index in 1...count {
            let progress = CGFloat(index) / CGFloat(count)
            let baseX = start.x + (end.x - start.x) * progress
            let baseY = start.y + (end.y - start.y) * progress
            let amount: CGFloat = index.isMultiple(of: 2) ? 7 : -7
            path.addLine(to: CGPoint(
                x: baseX + normal.x / length * amount,
                y: baseY + normal.y / length * amount
            ))
        }
    }

}
