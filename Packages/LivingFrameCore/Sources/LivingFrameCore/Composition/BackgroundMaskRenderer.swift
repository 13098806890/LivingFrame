import CoreGraphics
import Foundation

/// 背景图片元素的区域遮罩与边缘绘制。
/// 遮罩在元素自己的局部坐标中生成，因此图片整体移动/缩放/旋转时边缘不会抖动。
enum BackgroundMaskRenderer {
    private static let maskCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private static let edgeCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private static let canvasContentMaskCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 6
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private static let canvasOpeningMaskCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 6
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func clearCaches() {
        maskCache.removeAllObjects()
        edgeCache.removeAllObjects()
        canvasContentMaskCache.removeAllObjects()
        canvasOpeningMaskCache.removeAllObjects()
    }
    /// 画布级手撕相纸叠层。
    static func canvasEdgeImage(
        size: CGSize,
        style: CanvasEdgeStyle
    ) -> CGImage? {
        guard let parameters = canvasEdgeParameters(size: size, style: style) else {
            return nil
        }
        return PaperEffectRenderer.borderOverlay(
            size: size,
            profile: parameters.profile,
            borderInset: parameters.inset,
            foldedCorner: parameters.corner
        )
    }

    /// Masks the already-composited canvas to the same opening used by the
    /// authored paper frame. Without this, transparent pixels outside the torn
    /// frame reveal the original full-bleed photo underneath the overlay.
    static func canvasContentMaskImage(
        size: CGSize,
        style: CanvasEdgeStyle
    ) -> CGImage? {
        guard let parameters = canvasEdgeParameters(size: size, style: style) else {
            return nil
        }
        let key = "canvas-content-mask-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))-\(style.rawValue)" as NSString
        if let cached = canvasContentMaskCache.object(forKey: key) { return cached }
        let image = ProceduralRasterRenderer.makeImage(size: size) { context, rect in
            let opening = PaperAssetRenderer.destinationOpeningRect(
                size: size,
                profile: parameters.profile,
                borderInset: parameters.inset
            )
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            // The transparent frame asset has a rectangular photo opening.
            // Start with that opening, then remove every non-transparent pixel
            // from the actual frame alpha. This is important for the curled
            // corner, which crosses into the rectangular opening.
            context.fill(opening)
            if let frame = PaperAssetRenderer.borderOverlay(
                size: size,
                profile: parameters.profile,
                borderInset: parameters.inset,
                foldedCorner: parameters.corner
            ) {
                context.saveGState()
                // Destination-out uses the frame's alpha as the eraser. The
                // `.clear` blend mode would clear the entire draw rectangle,
                // including the actual photo opening.
                context.setBlendMode(.destinationOut)
                context.draw(frame, in: rect)
                context.restoreGState()
            }
        }
        if let image {
            canvasContentMaskCache.setObject(image, forKey: key, cost: imageCost(image))
        }
        return image
    }

    /// 只限制到相纸的几何开口，不扣除边框 PNG 的 alpha。
    ///
    /// 这个 mask 专门用于支持画布边框的图层排序：当边框位于内容下方时，
    /// 上层内容可以覆盖边框和卷角进入开口的部分；当边框位于内容上方时，
    /// 边框自身的透明 PNG 会自然覆盖在内容之上。
    static func canvasOpeningMaskImage(
        size: CGSize,
        style: CanvasEdgeStyle
    ) -> CGImage? {
        guard let parameters = canvasEdgeParameters(size: size, style: style) else {
            return nil
        }
        let key = "canvas-opening-mask-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))-\(style.rawValue)" as NSString
        if let cached = canvasOpeningMaskCache.object(forKey: key) { return cached }
        let image = ProceduralRasterRenderer.makeImage(size: size) { context, _ in
            let opening = PaperAssetRenderer.destinationOpeningRect(
                size: size,
                profile: parameters.profile,
                borderInset: parameters.inset
            )
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(opening)
        }
        if let image {
            canvasOpeningMaskCache.setObject(image, forKey: key, cost: imageCost(image))
        }
        return image
    }

    private static func canvasEdgeParameters(
        size: CGSize,
        style: CanvasEdgeStyle
    ) -> (profile: TornEdgeProfile, inset: CGFloat, corner: PaperFoldCorner?)? {
        guard style != .none else { return nil }
        let profile: TornEdgeProfile
        let baseInset: CGFloat
        let shortSide = min(size.width, size.height)
        switch style {
        case .none:
            return nil
        case .tornSoft:
            profile = .soft
            baseInset = min(max(shortSide * 0.040, 22), 60)
        case .tornLayered:
            profile = .layered
            baseInset = min(max(shortSide * 0.058, 34), 92)
        }
        return (
            profile,
            baseInset,
            style == .tornLayered ? .bottomRight : nil
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
        if let image { maskCache.setObject(image, forKey: key, cost: imageCost(image)) }
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
           settings.splitCount != .full,
           let authoredImage = PaperAssetRenderer.internalDividerOverlay(
               size: size,
               profile: profile,
               segments: internalDividerSegments(in: CGRect(origin: .zero, size: size), settings: settings)
           ) {
            edgeCache.setObject(authoredImage, forKey: key, cost: imageCost(authoredImage))
            return authoredImage
        }
        if let profile = tornProfile(for: settings.edgeStyle),
           let nativeImage = NativePaperEffectRenderer.tornEdgeOverlay(
               size: size,
               path: path(for: settings, in: CGRect(origin: .zero, size: size)),
               profile: profile
           ) {
            edgeCache.setObject(nativeImage, forKey: key, cost: imageCost(nativeImage))
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
        if let image { edgeCache.setObject(image, forKey: key, cost: imageCost(image)) }
        return image
    }

    private static func imageCost(_ image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, 1)
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
                sign: sign,
                edgeStyle: settings.edgeStyle
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
            sign: secondSign,
            edgeStyle: settings.edgeStyle,
            canvas: rect
        )
    }

    private static func normalizedAngle(_ degrees: CGFloat) -> CGFloat {
        let safe = degrees.isFinite ? degrees : 90
        let normalized = safe.truncatingRemainder(dividingBy: 180)
        return (normalized < 0 ? normalized + 180 : normalized) * .pi / 180
    }

    /// 分割边缘只向素材自身一侧轻微后退。相邻两侧都会贡献内退距离，
    /// 因此这里使用共用的窄缝参数，避免留白比纸张纹理本身还宽。
    private static func insetDividerCenter(
        _ center: CGPoint,
        normal: CGPoint,
        sign: CGFloat,
        edgeStyle: BackgroundEdgeStyle,
        in rect: CGRect
    ) -> CGPoint {
        let inset = BackgroundDividerGeometry.edgeInset(for: edgeStyle, in: rect)
        guard inset > 0 else { return center }
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
        sign: CGFloat,
        edgeStyle: BackgroundEdgeStyle
    ) -> CGPath {
        clippedPath(
            rectanglePolygon(rect),
            center: center,
            normal: normal,
            sign: sign,
            edgeStyle: edgeStyle,
            canvas: rect
        )
    }

    private static func clippedPath(
        _ polygon: [CGPoint],
        center: CGPoint,
        normal: CGPoint,
        sign: CGFloat,
        edgeStyle: BackgroundEdgeStyle,
        canvas: CGRect
    ) -> CGPath {
        let clipped = clippedPolygon(
            polygon,
            center: center,
            normal: normal,
            sign: sign
        )
        return paperPath(clipped, edgeStyle: edgeStyle, canvas: canvas)
    }

    /// Returns only the internal sides of the selected partition. The existing
    /// mask remains unchanged; this geometry is used only by the authored
    /// transparent paper overlay.
    private static func internalDividerSegments(
        in rect: CGRect,
        settings: BackgroundElementSettings
    ) -> [(CGPoint, CGPoint)] {
        guard settings.splitCount != .full else { return [] }

        let angle = normalizedAngle(settings.dividerAngle)
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: direction.y, y: -direction.x)
        let partition = max(
            0,
            min(settings.selectedPartition, settings.splitCount == .two ? 1 : 3)
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
            return internalSegments(
                of: clippedPolygon(rectanglePolygon(rect), center: center, normal: normal, sign: sign),
                in: rect
            )
        }

        let secondNormal = CGPoint(x: -direction.x, y: -direction.y)
        let firstSign: CGFloat = partition == 0 || partition == 3 ? 1 : -1
        let secondSign: CGFloat = partition == 0 || partition == 1 ? 1 : -1
        let firstCenter = insetDividerCenter(
            BackgroundDividerGeometry.center(
                in: rect,
                normal: normal,
                offset: settings.primaryDividerOffset
            ),
            normal: normal,
            sign: firstSign,
            edgeStyle: settings.edgeStyle,
            in: rect
        )
        let secondCenter = insetDividerCenter(
            BackgroundDividerGeometry.center(
                in: rect,
                normal: secondNormal,
                offset: settings.secondaryDividerOffset
            ),
            normal: secondNormal,
            sign: secondSign,
            edgeStyle: settings.edgeStyle,
            in: rect
        )
        let firstClipped = clippedPolygon(
            rectanglePolygon(rect),
            center: firstCenter,
            normal: normal,
            sign: firstSign
        )
        let partitionPolygon = clippedPolygon(
            firstClipped,
            center: secondCenter,
            normal: secondNormal,
            sign: secondSign
        )
        return internalSegments(of: partitionPolygon, in: rect)
    }

    private static func internalSegments(
        of polygon: [CGPoint],
        in rect: CGRect
    ) -> [(CGPoint, CGPoint)] {
        guard polygon.count > 1 else { return [] }
        return polygon.indices.compactMap { index in
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            return isCanvasBoundary(from: start, to: end, in: rect)
                ? nil
                : (start, end)
        }
    }

    /// Only divider segments receive the torn geometry. Segments coincident
    /// with the canvas perimeter remain straight and are later covered by the
    /// optional canvas frame, avoiding a second dark outline around the image.
    private static func paperPath(
        _ polygon: [CGPoint],
        edgeStyle: BackgroundEdgeStyle,
        canvas: CGRect
    ) -> CGPath {
        let path = CGMutablePath()
        guard let first = polygon.first else { return path }
        path.move(to: first)
        let profile = tornProfile(for: edgeStyle)
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            if let profile, !isCanvasBoundary(from: start, to: end, in: canvas) {
                TornEdgeGeometry.addLine(
                    from: start,
                    to: end,
                    profile: profile,
                    seed: 0xD1A1_D000 &+ UInt64(index) &* 0x9E37,
                    in: path
                )
            } else {
                path.addLine(to: end)
            }
        }
        path.closeSubpath()
        return path
    }

    private static func isCanvasBoundary(from start: CGPoint, to end: CGPoint, in rect: CGRect) -> Bool {
        let tolerance: CGFloat = 0.75
        return (abs(start.x - rect.minX) < tolerance && abs(end.x - rect.minX) < tolerance)
            || (abs(start.x - rect.maxX) < tolerance && abs(end.x - rect.maxX) < tolerance)
            || (abs(start.y - rect.minY) < tolerance && abs(end.y - rect.minY) < tolerance)
            || (abs(start.y - rect.maxY) < tolerance && abs(end.y - rect.maxY) < tolerance)
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
        case .tornSoft: return .soft
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
