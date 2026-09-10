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
    /// 拼接编辑器允许的最大分割线数量，避免画布和控制面板过度拥挤。
    public static let maximumDividerCount = 4

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
        let angle = radians(angle(for: dividerIndex, settings: settings))
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
        return first
    }

    public static func angle(
        for dividerIndex: Int,
        settings: BackgroundElementSettings
    ) -> CGFloat {
        switch dividerIndex {
        case 0:
            return settings.dividerAngle
        case 1:
            return settings.secondaryDividerAngle
        default:
            return settings.dividerLines.indices.contains(dividerIndex)
                ? settings.dividerLines[dividerIndex].angle
                : 90
        }
    }

    public static func dividerCount(for settings: BackgroundElementSettings) -> Int {
        settings.dividerLines.count
    }

    /// 根据当前分割线排列生成所有可见区域。
    /// 每条线都会切割当前已有的多边形，因此两条平行线自然得到 3 个区域，
    /// 两条相交线自然得到 4 个区域，后续也可以无缝支持更多分割线。
    public static func regions(
        for settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace,
        applyingEdgeInset: Bool = true
    ) -> [[CGPoint]] {
        guard !settings.dividerLines.isEmpty else {
            return [rectanglePolygon(in: rect)]
        }

        var regions: [([CGPoint], [Bool])] = [(rectanglePolygon(in: rect), [])]
        for dividerIndex in settings.dividerLines.indices {
            let normal = normal(
                for: dividerIndex,
                settings: settings,
                coordinateSpace: coordinateSpace
            )
            var next: [([CGPoint], [Bool])] = []
            for (polygon, signs) in regions {
                for sign: CGFloat in [1, -1] {
                    let center = adjustedDividerCenter(
                        for: dividerIndex,
                        settings: settings,
                        in: rect,
                        coordinateSpace: coordinateSpace,
                        sign: sign,
                        applyingEdgeInset: applyingEdgeInset
                    )
                    let clipped = clippedPolygon(
                        polygon,
                        center: center,
                        normal: normal,
                        sign: sign
                    )
                    guard polygonArea(clipped) > 0.01 else { continue }
                    next.append((clipped, signs + [sign > 0]))
                }
            }
            regions = next
        }

        let polygons = regions.map(\.0)
        // 保持旧工程中四区的区域编号顺序：++, -+, --, +-。
        // 新的任意分割线模式仍使用几何生成顺序，不依赖固定象限。
        if settings.dividerLines.count == 2, polygons.count == 4 {
            return [polygons[0], polygons[2], polygons[3], polygons[1]]
        }
        return polygons
    }

    public static func regionCount(
        for settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace = .screen
    ) -> Int {
        regions(
            for: settings,
            in: rect,
            coordinateSpace: coordinateSpace,
            applyingEdgeInset: false
        ).count
    }

    public static func dividerCenter(
        for dividerIndex: Int,
        settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace
    ) -> CGPoint {
        BackgroundDividerGeometry.lineCenter(
            in: rect,
            normal: normal(for: dividerIndex, settings: settings, coordinateSpace: coordinateSpace),
            offset: BackgroundDividerGeometry.offset(for: dividerIndex, settings: settings)
        )
    }

    /// 返回两条分割线在画布内的交点；平行或交点落在画布外时返回 nil。
    public static func intersection(
        of firstDividerIndex: Int,
        and secondDividerIndex: Int,
        settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace = .screen
    ) -> CGPoint? {
        guard firstDividerIndex != secondDividerIndex,
              settings.dividerLines.indices.contains(firstDividerIndex),
              settings.dividerLines.indices.contains(secondDividerIndex),
              rect.width > 0,
              rect.height > 0 else { return nil }

        let firstCenter = dividerCenter(
            for: firstDividerIndex,
            settings: settings,
            in: rect,
            coordinateSpace: coordinateSpace
        )
        let secondCenter = dividerCenter(
            for: secondDividerIndex,
            settings: settings,
            in: rect,
            coordinateSpace: coordinateSpace
        )
        let firstNormal = normal(
            for: firstDividerIndex,
            settings: settings,
            coordinateSpace: coordinateSpace
        )
        let secondNormal = normal(
            for: secondDividerIndex,
            settings: settings,
            coordinateSpace: coordinateSpace
        )
        let firstDirection = CGPoint(x: -firstNormal.y, y: firstNormal.x)
        let secondDirection = CGPoint(x: -secondNormal.y, y: secondNormal.x)
        let denominator = firstDirection.x * secondDirection.y
            - firstDirection.y * secondDirection.x
        guard abs(denominator) > 0.0001 else { return nil }

        let between = CGPoint(
            x: secondCenter.x - firstCenter.x,
            y: secondCenter.y - firstCenter.y
        )
        let firstParameter = (between.x * secondDirection.y
            - between.y * secondDirection.x) / denominator
        let point = CGPoint(
            x: firstCenter.x + firstDirection.x * firstParameter,
            y: firstCenter.y + firstDirection.y * firstParameter
        )
        let tolerance: CGFloat = 0.5
        guard point.x >= rect.minX - tolerance,
              point.x <= rect.maxX + tolerance,
              point.y >= rect.minY - tolerance,
              point.y <= rect.maxY + tolerance else { return nil }
        return point
    }

    /// 返回两条相交分割线的较小夹角，范围为 0...90°。
    public static func intersectionAngle(
        between firstDividerIndex: Int,
        and secondDividerIndex: Int,
        settings: BackgroundElementSettings
    ) -> CGFloat? {
        guard settings.dividerLines.indices.contains(firstDividerIndex),
              settings.dividerLines.indices.contains(secondDividerIndex) else { return nil }
        let difference = abs(
            angle(for: firstDividerIndex, settings: settings)
                - angle(for: secondDividerIndex, settings: settings)
        )
            .truncatingRemainder(dividingBy: 180)
        return min(difference, 180 - difference)
    }

    public static func pivot(
        for dividerIndex: Int,
        in rect: CGRect,
        settings: BackgroundElementSettings,
        coordinateSpace: BackgroundCoordinateSpace
    ) -> CGPoint {
        let storedPivot: CGPoint
        switch dividerIndex {
        case 0:
            storedPivot = settings.primaryDividerPivot
        case 1:
            storedPivot = settings.secondaryDividerPivot
        default:
            storedPivot = settings.dividerLines.indices.contains(dividerIndex)
                ? settings.dividerLines[dividerIndex].pivot
                : CGPoint(x: 0.5, y: 0.5)
        }
        let normalized = BackgroundDividerGeometry.clampedPivot(storedPivot)
        let storedPoint: CGPoint
        switch coordinateSpace {
        case .coreImage:
            storedPoint = CGPoint(
                x: rect.minX + normalized.x * rect.width,
                y: rect.minY + normalized.y * rect.height
            )
        case .screen:
            storedPoint = CGPoint(
                x: rect.minX + normalized.x * rect.width,
                y: rect.maxY - normalized.y * rect.height
            )
        }
        let center = dividerCenter(
            for: dividerIndex,
            settings: settings,
            in: rect,
            coordinateSpace: coordinateSpace
        )
        let dividerNormal = normal(for: dividerIndex, settings: settings, coordinateSpace: coordinateSpace)
        let distance = (storedPoint.x - center.x) * dividerNormal.x
            + (storedPoint.y - center.y) * dividerNormal.y
        let projected = CGPoint(
            x: storedPoint.x - dividerNormal.x * distance,
            y: storedPoint.y - dividerNormal.y * distance
        )
        return clampedToDividerSegment(projected, center: center, normal: dividerNormal, in: rect)
    }

    public static func normalizedPivot(
        at point: CGPoint,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace
    ) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let x = (point.x - rect.minX) / rect.width
        let y: CGFloat
        switch coordinateSpace {
        case .coreImage:
            y = (point.y - rect.minY) / rect.height
        case .screen:
            y = (rect.maxY - point.y) / rect.height
        }
        return BackgroundDividerGeometry.clampedPivot(CGPoint(x: x, y: y))
    }

    /// 将触点投影到指定分割线，并限制在画布内可见的分割线段上。
    public static func projectedPivot(
        at point: CGPoint,
        for dividerIndex: Int,
        settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace
    ) -> CGPoint {
        let center = dividerCenter(
            for: dividerIndex,
            settings: settings,
            in: rect,
            coordinateSpace: coordinateSpace
        )
        let dividerNormal = normal(for: dividerIndex, settings: settings, coordinateSpace: coordinateSpace)
        let distance = (point.x - center.x) * dividerNormal.x
            + (point.y - center.y) * dividerNormal.y
        let projected = CGPoint(
            x: point.x - dividerNormal.x * distance,
            y: point.y - dividerNormal.y * distance
        )
        return clampedToDividerSegment(projected, center: center, normal: dividerNormal, in: rect)
    }

    /// 返回当前元素在指定坐标系中的分区多边形。
    public static func polygon(
        for settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace,
        applyingEdgeInset: Bool = true
    ) -> [CGPoint] {
        let polygons = regions(
            for: settings,
            in: rect,
            coordinateSpace: coordinateSpace,
            applyingEdgeInset: applyingEdgeInset
        )
        guard !polygons.isEmpty else { return [] }
        return polygons[min(max(settings.selectedPartition, 0), polygons.count - 1)]
    }

    /// 返回一个素材实例覆盖的全部分区多边形。多个多边形属于同一个实例时，
    /// 渲染层会把它们作为一个联合遮罩处理。
    public static func assignedPolygons(
        for settings: BackgroundElementSettings,
        in rect: CGRect,
        coordinateSpace: BackgroundCoordinateSpace,
        applyingEdgeInset: Bool = true
    ) -> [[CGPoint]] {
        let polygons = regions(
            for: settings,
            in: rect,
            coordinateSpace: coordinateSpace,
            applyingEdgeInset: applyingEdgeInset
        )
        guard !polygons.isEmpty, !settings.resolvedAssignedPartitions.isEmpty else { return [] }
        let indexes = settings.resolvedAssignedPartitions
            .filter { $0 < polygons.count }
        return indexes.map { polygons[$0] }
    }

    public static func samplePoint(
        settings: BackgroundElementSettings,
        in rect: CGRect
    ) -> CGPoint {
        let polygons = regions(
            for: settings,
            in: rect,
            coordinateSpace: .screen,
            applyingEdgeInset: false
        )
        guard !polygons.isEmpty else { return CGPoint(x: rect.midX, y: rect.midY) }
        let index = min(max(settings.selectedPartition, 0), polygons.count - 1)
        return clampedToRect(centroid(of: polygons[index]), rect: rect)
    }

    public static func partition(
        at point: CGPoint,
        settings: BackgroundElementSettings,
        in rect: CGRect
    ) -> Int? {
        let polygons = regions(
            for: settings,
            in: rect,
            coordinateSpace: .screen,
            applyingEdgeInset: false
        )
        for (index, polygon) in polygons.enumerated()
            where contains(point, in: polygon) {
            return index
        }
        return nil
    }

    public static func dividerIndex(
        near point: CGPoint,
        settings: BackgroundElementSettings,
        in rect: CGRect,
        threshold: CGFloat
    ) -> Int? {
        let count = settings.dividerLines.count
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

    private static func polygonArea(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        let sum = polygon.indices.reduce(CGFloat.zero) { partial, index in
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            return partial + current.x * next.y - next.x * current.y
        }
        return abs(sum) * 0.5
    }

    private static func centroid(of polygon: [CGPoint]) -> CGPoint {
        guard !polygon.isEmpty else { return .zero }
        let areaSum = polygon.indices.reduce(CGFloat.zero) { partial, index in
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            return partial + current.x * next.y - next.x * current.y
        }
        guard abs(areaSum) > 0.0001 else {
            let sum = polygon.reduce(into: CGPoint.zero) { result, point in
                result.x += point.x
                result.y += point.y
            }
            return CGPoint(
                x: sum.x / CGFloat(polygon.count),
                y: sum.y / CGFloat(polygon.count)
            )
        }
        let weighted = polygon.indices.reduce(into: CGPoint.zero) { result, index in
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            let cross = current.x * next.y - next.x * current.y
            result.x += (current.x + next.x) * cross
            result.y += (current.y + next.y) * cross
        }
        return CGPoint(
            x: weighted.x / (3 * areaSum),
            y: weighted.y / (3 * areaSum)
        )
    }

    private static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        for index in polygon.indices {
            let current = polygon[index]
            let previous = polygon[(index + polygon.count - 1) % polygon.count]
            let crosses = (current.y > point.y) != (previous.y > point.y)
            guard crosses else { continue }
            let xAtPoint = (previous.x - current.x) * (point.y - current.y)
                / (previous.y - current.y) + current.x
            if point.x < xAtPoint {
                inside.toggle()
            }
        }
        return inside
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

    private static func clampedToDividerSegment(
        _ point: CGPoint,
        center: CGPoint,
        normal: CGPoint,
        in rect: CGRect
    ) -> CGPoint {
        let direction = CGPoint(x: -normal.y, y: normal.x)
        let epsilon: CGFloat = 0.0001
        var parameters: [CGFloat] = []

        if abs(direction.y) > epsilon {
            let bottom = (rect.minY - center.y) / direction.y
            let bottomX = center.x + bottom * direction.x
            if bottom.isFinite, bottomX >= rect.minX - epsilon, bottomX <= rect.maxX + epsilon {
                parameters.append(bottom)
            }
            let top = (rect.maxY - center.y) / direction.y
            let topX = center.x + top * direction.x
            if top.isFinite, topX >= rect.minX - epsilon, topX <= rect.maxX + epsilon {
                parameters.append(top)
            }
        }
        if abs(direction.x) > epsilon {
            let left = (rect.minX - center.x) / direction.x
            let leftY = center.y + left * direction.y
            if left.isFinite, leftY >= rect.minY - epsilon, leftY <= rect.maxY + epsilon {
                parameters.append(left)
            }
            let right = (rect.maxX - center.x) / direction.x
            let rightY = center.y + right * direction.y
            if right.isFinite, rightY >= rect.minY - epsilon, rightY <= rect.maxY + epsilon {
                parameters.append(right)
            }
        }

        guard let minimum = parameters.min(), let maximum = parameters.max() else {
            return point
        }
        let parameter = (point.x - center.x) * direction.x
            + (point.y - center.y) * direction.y
        let clamped = min(max(parameter, minimum), maximum)
        return CGPoint(
            x: center.x + clamped * direction.x,
            y: center.y + clamped * direction.y
        )
    }
}
