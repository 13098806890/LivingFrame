import CoreGraphics
import CoreImage
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
        let image = makeImage(size: size, transparent: true) { context, rect in
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
        guard settings.edgeStyle == .comic else { return nil }
        let key = cacheKey(prefix: "edge", size: size, settings: settings)
        if let cached = edgeCache.object(forKey: key) { return cached }
        let image = makeImage(size: size, transparent: true) { context, rect in
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
            return clippedPath(
                in: rect,
                center: BackgroundDividerGeometry.center(
                    in: rect,
                    normal: normal,
                    offset: settings.primaryDividerOffset
                ),
                normal: normal,
                sign: sign
            )
        }

        // 4 区由两条互相垂直、可独立平移的分割线组成。
        // 分区编号按 (+,+)、(-,+)、(-,-)、(+,-) 排列。
        let secondNormal = CGPoint(x: -direction.x, y: -direction.y)
        let firstSign: CGFloat = partition == 0 || partition == 3 ? 1 : -1
        let secondSign: CGFloat = partition == 0 || partition == 1 ? 1 : -1
        let firstCenter = BackgroundDividerGeometry.center(
            in: rect,
            normal: normal,
            offset: settings.primaryDividerOffset
        )
        let secondCenter = BackgroundDividerGeometry.center(
            in: rect,
            normal: secondNormal,
            offset: settings.secondaryDividerOffset
        )
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
        let safe = degrees.isFinite ? degrees : 45
        let normalized = safe.truncatingRemainder(dividingBy: 180)
        return (normalized < 0 ? normalized + 180 : normalized) * .pi / 180
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
            path.addRect(CGRect(
                x: rect.midX,
                y: rect.midY,
                width: rect.width / 2,
                height: rect.height / 2
            ))
        case .diagonal:
            path.move(to: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: right, y: top))
            if edgeStyle == .zigzag {
                addZigzag(from: CGPoint(x: right, y: bottom), to: CGPoint(x: left, y: top), in: path)
            } else if edgeStyle == .torn {
                addTorn(from: CGPoint(x: right, y: bottom), to: CGPoint(x: left, y: top), in: path)
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
        let angle = Int(settings.dividerAngle.isFinite ? settings.dividerAngle.rounded() : 45)
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
        let step: CGFloat = edgeStyle == .zigzag ? 28 : 42
        let count = max(Int(abs(start - end) / step), 1)
        for index in 1...count {
            let progress = CGFloat(index) / CGFloat(count)
            let x = start + (end - start) * progress
            let y: CGFloat
            if edgeStyle == .zigzag {
                let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                y = baseline + direction * min(rect.height * 0.045, 18)
            } else {
                let wave = sin(progress * .pi * 7) * min(rect.height * 0.035, 14)
                let irregular = CGFloat((index * 17) % 9 - 4)
                y = baseline + wave + irregular
            }
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }

    private static func addTorn(from start: CGPoint, to end: CGPoint, in path: CGMutablePath) {
        let count = 18
        for index in 1...count {
            let progress = CGFloat(index) / CGFloat(count)
            let baseX = start.x + (end.x - start.x) * progress
            let baseY = start.y + (end.y - start.y) * progress
            let normal = CGPoint(x: -(end.y - start.y), y: end.x - start.x)
            let length = max(sqrt(normal.x * normal.x + normal.y * normal.y), 1)
            let amount = CGFloat((index * 13) % 11 - 5) / length * 8
            path.addLine(to: CGPoint(x: baseX + normal.x * amount, y: baseY + normal.y * amount))
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

    private static func makeImage(
        size: CGSize,
        transparent: Bool,
        draw: (CGContext, CGRect) -> Void
    ) -> CGImage? {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        if transparent {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        }
        draw(context, CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
