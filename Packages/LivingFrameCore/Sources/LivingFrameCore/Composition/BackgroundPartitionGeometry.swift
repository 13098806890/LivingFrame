import CoreGraphics
import Foundation

/// 坐标系方向。Core Image 使用 y 向上，SwiftUI 画布使用 y 向下。
public enum BackgroundCoordinateSpace: Sendable {
    case coreImage
    case screen
}

/// 拼接分区的唯一几何实现。
///
/// 分区遮罩、检查器预览、分区命中测试和分割线拖动都必须使用同一套法线、
/// 分割线中心和多边形裁剪规则，避免预览与导出出现半像素或方向偏差。
public enum BackgroundPartitionGeometry {
    public static func radians(_ degrees: CGFloat) -> CGFloat {
        let normalized = (degrees.isFinite ? degrees : 90)
            .truncatingRemainder(dividingBy: 180)
        return (normalized < 0 ? normalized + 180 : normalized) * .pi / 180
    }

    public static func normal(
        for dividerIndex: Int,
        settings: BackgroundElementSettings,
        coordinateSpace: BackgroundCoordinateSpace
    ) -> CGPoint {
        let angle = radians(settings.dividerAngle)
        let direction: CGPoint
        switch coordinateSpace {
        case .coreImage:
            direction = CGPoint(x: cos(angle), y: sin(angle))
        case .screen:
            direction = CGPoint(x: cos(angle), y: -sin(angle))
        }
        let first: CGPoint
        switch coordinateSpace {
        case .coreImage:
            // Core Image 的 y 轴向上；保持与旧遮罩算法相同的法线方向。
            first = CGPoint(x: direction.y, y: -direction.x)
        case .screen:
            first = CGPoint(x: -direction.y, y: direction.x)
        }
        return dividerIndex == 0
            ? first
            : CGPoint(x: -direction.x, y: -direction.y)
    }

    public static func dividerCenter(
        for dividerIndex: Int,
        settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace
    ) -> CGPoint {
        BackgroundDividerGeometry.center(
            in: rect,
            normal: normal(for: dividerIndex, settings: settings, coordinateSpace: coordinateSpace),
            offset: BackgroundDividerGeometry.offset(for: dividerIndex, settings: settings)
        )
    }

    /// 返回当前元素在指定坐标系中的分区多边形。
    public static func polygon(
        for settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace,
        applyingEdgeInset: Bool = true
    ) -> [CGPoint] {
        guard settings.splitCount != .full else { return rectanglePolygon(in: rect) }

        let firstNormal = normal(for: 0, settings: settings, coordinateSpace: coordinateSpace)
        if settings.splitCount == .two {
            let firstSign: CGFloat = settings.selectedPartition == 0 ? 1 : -1
            let firstCenter = adjustedDividerCenter(
                for: 0,
                settings: settings,
                in: rect,
                coordinateSpace: coordinateSpace,
                sign: firstSign,
                applyingEdgeInset: applyingEdgeInset
            )
            return clippedPolygon(
                rectanglePolygon(in: rect),
                center: firstCenter,
                normal: firstNormal,
                sign: firstSign
            )
        }

        let firstSign: CGFloat = settings.selectedPartition == 0 || settings.selectedPartition == 3 ? 1 : -1
        let secondSign: CGFloat = settings.selectedPartition == 0 || settings.selectedPartition == 1 ? 1 : -1
        let secondNormal = normal(for: 1, settings: settings, coordinateSpace: coordinateSpace)
        let firstCenter = adjustedDividerCenter(
            for: 0,
            settings: settings,
            in: rect,
            coordinateSpace: coordinateSpace,
            sign: firstSign,
            applyingEdgeInset: applyingEdgeInset
        )
        let secondCenter = adjustedDividerCenter(
            for: 1,
            settings: settings,
            in: rect,
            coordinateSpace: coordinateSpace,
            sign: secondSign,
            applyingEdgeInset: applyingEdgeInset
        )
        let firstClipped = clippedPolygon(
            rectanglePolygon(in: rect),
            center: firstCenter,
            normal: firstNormal,
            sign: firstSign
        )
        return clippedPolygon(
            firstClipped,
            center: secondCenter,
            normal: secondNormal,
            sign: secondSign
        )
    }

    public static func samplePoint(
        settings: BackgroundElementSettings,
        in rect: CGRect
    ) -> CGPoint {
        let firstNormal = normal(for: 0, settings: settings, coordinateSpace: .screen)
        let firstCenter = dividerCenter(
            for: 0,
            settings: settings,
            in: rect,
            coordinateSpace: .screen
        )
        if settings.splitCount == .two {
            let sign: CGFloat = settings.selectedPartition == 0 ? 1 : -1
            let distance = BackgroundDividerGeometry.extent(in: rect, normal: firstNormal) * 0.24 * sign
            return clampedToRect(
                CGPoint(
                    x: firstCenter.x + firstNormal.x * distance,
                    y: firstCenter.y + firstNormal.y * distance
                ),
                rect: rect
            )
        }

        let secondNormal = normal(for: 1, settings: settings, coordinateSpace: .screen)
        let firstSign: CGFloat = settings.selectedPartition == 0 || settings.selectedPartition == 3 ? 1 : -1
        let secondSign: CGFloat = settings.selectedPartition == 0 || settings.selectedPartition == 1 ? 1 : -1
        let firstDistance = BackgroundDividerGeometry.extent(in: rect, normal: firstNormal) * 0.2 * firstSign
        let secondDistance = BackgroundDividerGeometry.extent(in: rect, normal: secondNormal) * 0.2 * secondSign
        return clampedToRect(
            CGPoint(
                x: firstCenter.x + firstNormal.x * firstDistance + secondNormal.x * secondDistance,
                y: firstCenter.y + firstNormal.y * firstDistance + secondNormal.y * secondDistance
            ),
            rect: rect
        )
    }

    public static func partition(
        at point: CGPoint,
        settings: BackgroundElementSettings,
        in rect: CGRect
    ) -> Int? {
        guard settings.splitCount != .full else { return nil }
        let firstNormal = normal(for: 0, settings: settings, coordinateSpace: .screen)
        let firstCenter = dividerCenter(
            for: 0,
            settings: settings,
            in: rect,
            coordinateSpace: .screen
        )
        let firstValue = signedDistance(point, from: firstCenter, normal: firstNormal)
        if settings.splitCount == .two {
            return firstValue >= 0 ? 0 : 1
        }

        let secondNormal = normal(for: 1, settings: settings, coordinateSpace: .screen)
        let secondCenter = dividerCenter(
            for: 1,
            settings: settings,
            in: rect,
            coordinateSpace: .screen
        )
        let secondValue = signedDistance(point, from: secondCenter, normal: secondNormal)
        switch (firstValue >= 0, secondValue >= 0) {
        case (true, true): return 0
        case (false, true): return 1
        case (false, false): return 2
        case (true, false): return 3
        }
    }

    public static func dividerIndex(
        near point: CGPoint,
        settings: BackgroundElementSettings,
        in rect: CGRect,
        threshold: CGFloat
    ) -> Int? {
        let count = settings.splitCount == .four ? 2 : (settings.splitCount == .two ? 1 : 0)
        guard count > 0 else { return nil }
        let candidates = (0..<count).map { index in
            let center = dividerCenter(
                for: index,
                settings: settings,
                in: rect,
                coordinateSpace: .screen
            )
            let normal = normal(for: index, settings: settings, coordinateSpace: .screen)
            return (index, abs(signedDistance(point, from: center, normal: normal)))
        }
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= threshold else {
            return nil
        }
        return nearest.0
    }

    public static func clippedPolygon(
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
            let currentValue = signedDistance(current, from: center, normal: normal) * sign
            let previousValue = signedDistance(previous, from: center, normal: normal) * sign
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
            if currentInside { result.append(current) }
        }
        return result
    }

    private static func adjustedDividerCenter(
        for dividerIndex: Int,
        settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace,
        sign: CGFloat,
        applyingEdgeInset: Bool
    ) -> CGPoint {
        let center = dividerCenter(
            for: dividerIndex,
            settings: settings,
            in: rect,
            coordinateSpace: coordinateSpace
        )
        guard applyingEdgeInset else { return center }
        let inset = BackgroundDividerGeometry.edgeInset(for: settings.edgeStyle, in: rect)
        return CGPoint(x: center.x + normal(for: dividerIndex, settings: settings, coordinateSpace: coordinateSpace).x * sign * inset,
                       y: center.y + normal(for: dividerIndex, settings: settings, coordinateSpace: coordinateSpace).y * sign * inset)
    }

    private static func rectanglePolygon(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private static func signedDistance(
        _ point: CGPoint,
        from center: CGPoint,
        normal: CGPoint
    ) -> CGFloat {
        (point.x - center.x) * normal.x + (point.y - center.y) * normal.y
    }

    private static func clampedToRect(_ point: CGPoint, rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX + 24), rect.maxX - 24),
            y: min(max(point.y, rect.minY + 16), rect.maxY - 16)
        )
    }
}
