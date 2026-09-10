import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LivingFrameCore

final class BackgroundPartitionRenderingTests: XCTestCase {
    func testCollageAllowsAtMostFourDividerLines() {
        XCTAssertEqual(BackgroundPartitionGeometry.maximumDividerCount, 4)
    }

    func testEmptyCollageLayoutStartsWithoutDividerLines() {
        let settings = BackgroundElementSettings()

        XCTAssertTrue(settings.dividerLines.isEmpty)
        XCTAssertEqual(
            BackgroundPartitionGeometry.regionCount(
                for: settings,
                in: CGRect(x: 0, y: 0, width: 320, height: 180)
            ),
            1
        )
    }

    func testDividerLayoutLockDefaultsToEditableAndPersists() throws {
        XCTAssertFalse(BackgroundElementSettings().isDividerLayoutLocked)

        var settings = BackgroundElementSettings(
            splitCount: .two,
            dividerAngle: 45
        )
        settings.isDividerLayoutLocked = true

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(BackgroundElementSettings.self, from: data)

        XCTAssertTrue(restored.isDividerLayoutLocked)
    }

    func testOneDividerProducesTwoRegions() {
        let settings = BackgroundElementSettings(
            splitCount: .two,
            dividerAngle: 0
        )

        XCTAssertEqual(
            BackgroundPartitionGeometry.regionCount(
                for: settings,
                in: CGRect(x: 0, y: 0, width: 320, height: 180)
            ),
            2
        )
    }

    func testOneElementCanCoverMultipleRegionsWithOneSharedMask() throws {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        let settings = BackgroundElementSettings(
            splitCount: .two,
            dividerAngle: 0,
            selectedPartition: 0,
            assignedPartitions: [0, 1]
        )

        let assigned = BackgroundPartitionGeometry.assignedPolygons(
            for: settings,
            in: rect,
            coordinateSpace: .screen
        )
        XCTAssertEqual(assigned.count, 2)

        let restored = try JSONDecoder().decode(
            BackgroundElementSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.resolvedAssignedPartitions, [0, 1])
    }

    func testOneElementCanBeRemovedFromItsOnlyAssignedRegion() throws {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        let settings = BackgroundElementSettings(
            splitCount: .two,
            dividerAngle: 0,
            selectedPartition: 0,
            assignedPartitions: []
        )

        XCTAssertTrue(settings.resolvedAssignedPartitions.isEmpty)
        XCTAssertTrue(
            BackgroundPartitionGeometry.assignedPolygons(
                for: settings,
                in: rect,
                coordinateSpace: .screen
            ).isEmpty
        )

        let restored = try JSONDecoder().decode(
            BackgroundElementSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertTrue(restored.resolvedAssignedPartitions.isEmpty)
    }

    func testOneElementRendersAcrossTwoAssignedRegions() throws {
        let store = BackgroundStore.shared
        let imageID = try XCTUnwrap(
            store.saveUserImage(
                try pngData(fill: CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                preferredFileExtension: "png"
            )
        )
        defer { try? FileManager.default.removeItem(at: store.mediaURL(named: imageID)) }

        let element = CompositionElement(
            kind: .background(backgroundID: imageID),
            name: "shared-source",
            transform: ElementTransform(position: CGPoint(x: 80, y: 80)),
            startTime: 0,
            endTime: 1,
            backgroundSettings: BackgroundElementSettings(
                splitCount: .two,
                dividerAngle: 0,
                assignedPartitions: [0, 1]
            )
        )
        let composition = Composition(
            name: "Shared source",
            canvas: CanvasSpec(width: 160, height: 160),
            duration: 1,
            elements: [element]
        )

        let result = try XCTUnwrap(CompositionRenderer().render(composition, at: 0))
        XCTAssertLessThanOrEqual(colorDistance(rgb(in: result, x: 40, y: 40), RGB(red: 255, green: 0, blue: 0)), 70)
        XCTAssertLessThanOrEqual(colorDistance(rgb(in: result, x: 40, y: 120), RGB(red: 255, green: 0, blue: 0)), 70)
    }

    func testTwoParallelDividersProduceThreeRegions() {
        let settings = BackgroundElementSettings(
            splitCount: .four,
            dividerAngle: 0,
            secondaryDividerAngle: 0,
            primaryDividerOffset: -0.25,
            secondaryDividerOffset: 0.25
        )

        XCTAssertEqual(
            BackgroundPartitionGeometry.regionCount(
                for: settings,
                in: CGRect(x: 0, y: 0, width: 320, height: 180)
            ),
            3
        )
    }

    func testTwoCrossingDividersProduceFourRegions() {
        let settings = BackgroundElementSettings(
            splitCount: .four,
            dividerAngle: 0,
            secondaryDividerAngle: 90
        )

        XCTAssertEqual(
            BackgroundPartitionGeometry.regionCount(
                for: settings,
                in: CGRect(x: 0, y: 0, width: 320, height: 180)
            ),
            4
        )
    }

    func testIntersectingDividersExposeIntersectionPointAndAngle() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        let settings = BackgroundElementSettings(
            splitCount: .four,
            dividerAngle: 30,
            secondaryDividerAngle: 90
        )

        let intersection = BackgroundPartitionGeometry.intersection(
            of: 0,
            and: 1,
            settings: settings,
            in: rect
        )
        guard let intersection else {
            XCTFail("Expected the dividers to intersect inside the canvas")
            return
        }
        XCTAssertEqual(intersection.x, rect.midX, accuracy: 0.001)
        XCTAssertEqual(intersection.y, rect.midY, accuracy: 0.001)
        guard let angle = BackgroundPartitionGeometry.intersectionAngle(
            between: 0,
            and: 1,
            settings: settings
        ) else {
            XCTFail("Expected an angle for intersecting dividers")
            return
        }
        XCTAssertEqual(angle, 60, accuracy: 0.001)
    }

    func testSharedPartitionGeometryCoversCanvas() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        let areas = (0..<4).map { partition in
            let settings = BackgroundElementSettings(
                splitCount: .four,
                dividerAngle: 27,
                primaryDividerOffset: 0.12,
                secondaryDividerOffset: -0.18,
                selectedPartition: partition
            )
            return polygonArea(
                BackgroundPartitionGeometry.polygon(
                    for: settings,
                    in: rect,
                    coordinateSpace: .screen,
                    applyingEdgeInset: false
                )
            )
        }

        XCTAssertEqual(areas.reduce(0, +), rect.width * rect.height, accuracy: 0.01)
    }

    func testEachDividerUsesItsOwnRotationPivot() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        let settings = BackgroundElementSettings(
            splitCount: .four,
            dividerAngle: 0,
            secondaryDividerAngle: 90,
            secondaryDividerOffset: 0.5,
            primaryDividerPivot: CGPoint(x: 0.25, y: 0.5),
            secondaryDividerPivot: CGPoint(x: 0.75, y: 0.25)
        )

        let primary = BackgroundPartitionGeometry.dividerCenter(
            for: 0,
            settings: settings,
            in: rect,
            coordinateSpace: .screen
        )
        let secondary = BackgroundPartitionGeometry.dividerCenter(
            for: 1,
            settings: settings,
            in: rect,
            coordinateSpace: .screen
        )

        XCTAssertEqual(primary.x, 160, accuracy: 0.001)
        XCTAssertEqual(primary.y, 90, accuracy: 0.001)
        XCTAssertEqual(secondary.x, 240, accuracy: 0.001)
        XCTAssertEqual(secondary.y, 90, accuracy: 0.001)

        let primaryPivot = BackgroundPartitionGeometry.pivot(
            for: 0,
            in: rect,
            settings: settings,
            coordinateSpace: .screen
        )
        let secondaryPivot = BackgroundPartitionGeometry.pivot(
            for: 1,
            in: rect,
            settings: settings,
            coordinateSpace: .screen
        )
        XCTAssertEqual(primaryPivot.x, 80, accuracy: 0.001)
        XCTAssertEqual(primaryPivot.y, 90, accuracy: 0.001)
        XCTAssertEqual(secondaryPivot.x, 240, accuracy: 0.001)
        XCTAssertEqual(secondaryPivot.y, 135, accuracy: 0.001)
    }

    func testScreenPivotConvertsBackToNormalizedCoreImageCoordinates() {
        let rect = CGRect(x: 10, y: 20, width: 320, height: 180)
        let normalized = CGPoint(x: 0.2, y: 0.5)
        let screenPoint = BackgroundPartitionGeometry.pivot(
            for: 0,
            in: rect,
            settings: BackgroundElementSettings(
                dividerAngle: 0,
                primaryDividerPivot: normalized
            ),
            coordinateSpace: .screen
        )

        let roundTripped = BackgroundPartitionGeometry.normalizedPivot(
            at: screenPoint,
            in: rect,
            coordinateSpace: .screen
        )

        XCTAssertEqual(roundTripped.x, normalized.x, accuracy: 0.001)
        XCTAssertEqual(roundTripped.y, normalized.y, accuracy: 0.001)
    }

    func testChangingAngleCanKeepEachDividerPivotFixed() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        let settings = BackgroundElementSettings(
            splitCount: .four,
            dividerAngle: 0,
            secondaryDividerAngle: 90,
            primaryDividerPivot: CGPoint(x: 0.25, y: 0.5),
            secondaryDividerPivot: CGPoint(x: 0.75, y: 0.25)
        )
        let pivot = BackgroundPartitionGeometry.pivot(
            for: 0,
            in: rect,
            settings: settings,
            coordinateSpace: .coreImage
        )

        var rotated = settings
        rotated.dividerAngle = 90
        rotated.primaryDividerOffset = BackgroundDividerGeometry.offset(
            keeping: pivot,
            normal: BackgroundPartitionGeometry.normal(
                for: 0,
                settings: rotated,
                coordinateSpace: .coreImage
            ),
            in: rect
        )
        let rotatedCenter = BackgroundPartitionGeometry.dividerCenter(
            for: 0,
            settings: rotated,
            in: rect,
            coordinateSpace: .coreImage
        )

        XCTAssertEqual(rotatedCenter.x, pivot.x, accuracy: 0.001)
        XCTAssertEqual(rotatedCenter.y, pivot.y, accuracy: 0.001)
        XCTAssertEqual(rotated.secondaryDividerAngle, settings.secondaryDividerAngle, accuracy: 0.001)
    }

    func testRotatingDividerKeepsItsControlPointAsTheRotationCenter() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        var settings = BackgroundElementSettings(
            splitCount: .two,
            dividerAngle: 15,
            primaryDividerPivot: CGPoint(x: 0.25, y: 0.5)
        )
        let pivot = BackgroundPartitionGeometry.pivot(
            for: 0,
            in: rect,
            settings: settings,
            coordinateSpace: .coreImage
        )
        // 模拟 UI 将控制点投影到分割线后保存的归一化位置。
        settings.primaryDividerPivot = BackgroundPartitionGeometry.normalizedPivot(
            at: pivot,
            in: rect,
            coordinateSpace: .coreImage
        )

        settings.dividerAngle = 105
        settings.dividerLines[0].angle = 105
        settings.primaryDividerOffset = BackgroundDividerGeometry.offset(
            keeping: pivot,
            normal: BackgroundPartitionGeometry.normal(
                for: 0,
                settings: settings,
                coordinateSpace: .coreImage
            ),
            in: rect
        )
        settings.dividerLines[0].offset = settings.primaryDividerOffset

        let rotatedPivot = BackgroundPartitionGeometry.pivot(
            for: 0,
            in: rect,
            settings: settings,
            coordinateSpace: .coreImage
        )
        XCTAssertEqual(rotatedPivot.x, pivot.x, accuracy: 0.001)
        XCTAssertEqual(rotatedPivot.y, pivot.y, accuracy: 0.001)
    }

    func testFourBackgroundsRenderIntoFourIndependentPartitions() throws {
        let colors = [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        ]
        let store = BackgroundStore.shared
        let imageIDs = try colors.map { color in
            guard let id = store.saveUserImage(try pngData(fill: color), preferredFileExtension: "png") else {
                throw NSError(domain: "LivingFrameCoreTests", code: 1)
            }
            return id
        }
        defer {
            for id in imageIDs {
                try? FileManager.default.removeItem(at: store.mediaURL(named: id))
            }
        }

        let elements = imageIDs.enumerated().map { index, imageID in
            CompositionElement(
                kind: .background(backgroundID: imageID),
                name: "partition-\(index)",
                transform: ElementTransform(position: CGPoint(x: 80, y: 80)),
                zIndex: index,
                startTime: 0,
                endTime: 1,
                backgroundSettings: BackgroundElementSettings(
                    splitCount: .four,
                    dividerAngle: 0,
                    selectedPartition: index
                )
            )
        }
        let composition = Composition(
            name: "Four partitions",
            canvas: CanvasSpec(width: 160, height: 160),
            duration: 1,
            elements: elements
        )

        guard let result = CompositionRenderer().render(composition, at: 0) else {
            return XCTFail("Expected a rendered frame")
        }

        // 四个采样点不依赖 Core Graphics 的行原点约定；只要四个分区都被独立
        // 合成，采样集合就必须恰好包含四种源色。若遮罩被复用为同一个分区，会留下
        // 白色底图并立刻让这个断言失败。
        let samples = [
            rgb(in: result, x: 40, y: 40),
            rgb(in: result, x: 120, y: 40),
            rgb(in: result, x: 40, y: 120),
            rgb(in: result, x: 120, y: 120)
        ]
        let expected = [
            RGB(red: 255, green: 0, blue: 0),
            RGB(red: 0, green: 255, blue: 0),
            RGB(red: 0, green: 0, blue: 255),
            RGB(red: 255, green: 255, blue: 0)
        ]
        let nearest = samples.map { sample in
            expected.indices.min { colorDistance(sample, expected[$0]) < colorDistance(sample, expected[$1]) }!
        }
        XCTAssertEqual(Set(nearest), Set(expected.indices))
        for sample in samples {
            XCTAssertLessThanOrEqual(expected.map { colorDistance(sample, $0) }.min()!, 70)
        }
    }

    private func pngData(fill color: CGColor) throws -> Data {
        let size = 16
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "LivingFrameCoreTests", code: 2)
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else {
            throw NSError(domain: "LivingFrameCoreTests", code: 3)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "LivingFrameCoreTests", code: 4)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "LivingFrameCoreTests", code: 5)
        }
        return data as Data
    }

    private func rgb(in image: CGImage, x: Int, y: Int) -> RGB {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return RGB(red: -1, green: -1, blue: -1)
        }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return RGB(red: -1, green: -1, blue: -1) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return RGB(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }

    private func colorDistance(_ lhs: RGB, _ rhs: RGB) -> Int {
        abs(lhs.red - rhs.red) + abs(lhs.green - rhs.green) + abs(lhs.blue - rhs.blue)
    }

    private func polygonArea(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count > 2 else { return 0 }
        let sum = polygon.indices.reduce(CGFloat.zero) { partial, index in
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            return partial + current.x * next.y - next.x * current.y
        }
        return abs(sum) / 2
    }

    private struct RGB: Hashable {
        let red: Int
        let green: Int
        let blue: Int
    }
}
