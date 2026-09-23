import CoreImage
import Foundation
import Vision

public enum PersonSegmenterError: Error {
    case noSubject
    case renderFailed
}

/// 一个视频帧中由 Vision 识别出的前景实例。index 只在当前帧内有效，
/// 视频级别的主体 ID 由 VideoSegmentationPipeline 负责匹配。
public struct ForegroundInstanceInfo {
    public let index: Int
    public let area: Int
    /// 以图像左上角为原点的归一化包围盒，便于在预览图上标注主体。
    public let boundingBox: CGRect
    /// 掩码像素的中心。Vision 的 boundingBox 在遮挡和大动作时常会接近整幅画面，
    /// 中心点用于跨帧匹配实例。
    public let center: CGPoint
    /// 低分辨率掩码指纹，用于在两个主体靠近或包围盒都接近整幅画面时保持身份。
    /// 数组内容只表示采样格是否被实例掩码覆盖，不用于渲染。
    public let maskSignature: [UInt8]

    public init(
        index: Int,
        area: Int,
        boundingBox: CGRect,
        center: CGPoint = .zero,
        maskSignature: [UInt8] = []
    ) {
        self.index = index
        self.area = area
        self.boundingBox = boundingBox
        self.center = center
        self.maskSignature = maskSignature
    }
}

/// Vision mask source. The person request is the source of truth for this app:
/// it preserves person instances instead of collapsing all people into one
/// foreground subject. The generic foreground request remains available for
/// callers that explicitly need class-agnostic subject lifting.
public enum VisionMaskSource: String, Sendable {
    case person
    case foreground
}

/// 单帧人物抠图（iOS 17+ / macOS 14+）。
/// 使用 Vision 的 VNGeneratePersonInstanceMaskRequest，优先保证遮挡场景中的
/// 多人物拆分；它比通用前景实例请求更适合本应用的“人物剪影”素材。
public struct VisionPersonSegmenter {
    private let context: CIContext

    public init() {
        context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            // Segmentation creates a new full-frame mask for every input frame.
            // Keeping intermediate textures here causes the process footprint to
            // grow linearly during long video extraction.
            .cacheIntermediates: false
        ])
    }

    /// 返回当前帧的人物实例统计。Vision 的实例编号只在当前帧内有效。
    ///
    /// 这里不再用通用前景结果兜底。前景模型可能把袖子、衣服或旁边的
    /// 物体拆成额外实例，导致主体选择界面出现错误候选。
    public func instanceInfos(from cgImage: CGImage) throws -> [ForegroundInstanceInfo] {
        try instanceInfos(from: cgImage, source: .person)
    }

    /// 返回通用前景实例统计。视频渲染阶段使用它，但不会参与主体候选发现。
    public func foregroundInstanceInfos(from cgImage: CGImage) throws -> [ForegroundInstanceInfo] {
        try instanceInfos(from: cgImage, source: .foreground)
    }

    /// 在一次前景请求中找到与目标区域对应的实例并直接输出抠图。
    /// 视频渲染使用这个入口，避免先请求一次统计实例、再请求一次生成图像。
    public func segmentedForegroundImage(
        from cgImage: CGImage,
        matching targetBoxes: [CGRect]
    ) throws -> CGImage {
        guard !targetBoxes.isEmpty else { throw PersonSegmenterError.noSubject }
        let (observation, handler) = try performObservation(from: cgImage, source: .foreground)
        let infos = instanceInfos(in: observation, from: handler)
        let selected = matchInstances(infos, to: targetBoxes)
        guard !selected.isEmpty else { throw PersonSegmenterError.noSubject }
        guard let buffer = try? observation.generateMaskedImage(
            ofInstances: selected,
            from: handler,
            croppedToInstancesExtent: false
        ) else {
            throw PersonSegmenterError.noSubject
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let output = context.createCGImage(ci, from: ci.extent) else {
            throw PersonSegmenterError.renderFailed
        }
        LogStore.log(
            "xdz.vision.render source=foreground matchedInstances=\(selected.count)"
        )
        return output
    }

    /// 输出当前帧的全部通用前景实例。人物身份遮罩会在视频管线中再做
    /// 一次裁剪，因此这里不能只取面积最大的前景实例。
    public func segmentedForegroundImage(from cgImage: CGImage) throws -> CGImage {
        let (observation, handler) = try performObservation(from: cgImage, source: .foreground)
        let selected = observation.allInstances
        guard !selected.isEmpty,
              let buffer = try? observation.generateMaskedImage(
                  ofInstances: selected,
                  from: handler,
                  croppedToInstancesExtent: false
              ) else {
            throw PersonSegmenterError.noSubject
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let output = context.createCGImage(ci, from: ci.extent) else {
            throw PersonSegmenterError.renderFailed
        }
        LogStore.log("xdz.vision.render source=foreground selected=all")
        return output
    }

    public func instanceInfos(
        from cgImage: CGImage,
        source: VisionMaskSource
    ) throws -> [ForegroundInstanceInfo] {
        let (observation, handler) = try performObservation(from: cgImage, source: source)
        let infos = instanceInfos(in: observation, from: handler)
        let boxSummary = infos
            .map { "\($0.index):box=\($0.boundingBox):center=\($0.center)" }
            .joined(separator: ",")
        LogStore.log(
            "xdz.vision.instances source=\(source.rawValue) count=\(infos.count) boxes=\(boxSummary)"
        )
        return infos
    }

    /// 用用户在代表帧上画出的区域筛选实例。这里直接检查实例掩码像素，
    /// 不依赖 Vision 经常覆盖整幅画面的 boundingBox。
    public func instanceInfos(
        from cgImage: CGImage,
        source: VisionMaskSource,
        intersecting polygon: [CGPoint],
        minimumCoverage: Double = 0.20,
        minimumIntersectionPixels: Int = 24
    ) throws -> [ForegroundInstanceInfo] {
        let (observation, handler) = try performObservation(from: cgImage, source: source)
        var coverageSummary: [String] = []
        let infos = observation.allInstances.compactMap { instance -> ForegroundInstanceInfo? in
            guard let mask = try? observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: instance),
                from: handler
            ),
                  let stats = maskStatistics(mask),
                  let overlap = maskCoverage(mask, polygon: polygon) else { return nil }
            coverageSummary.append(
                "\(instance):coverage=\(String(format: "%.3f", overlap.coverage)):pixels=\(overlap.intersectionPixels)"
            )
            guard overlap.coverage >= minimumCoverage,
                  overlap.intersectionPixels >= minimumIntersectionPixels else { return nil }
            return ForegroundInstanceInfo(
                index: instance,
                area: stats.area,
                boundingBox: stats.boundingBox,
                center: stats.center,
                maskSignature: stats.maskSignature
            )
        }
        .sorted { $0.area > $1.area }
        LogStore.log(
            "xdz.vision.instances source=\(source.rawValue) regionFiltered="
                + "count=\(infos.count) minimumCoverage=\(minimumCoverage) "
                + "minimumPixels=\(minimumIntersectionPixels) "
                + "coverage=[\(coverageSummary.joined(separator: ","))]"
        )
        return infos
    }

    /// 输出带透明通道的主体图（保留原始帧尺寸，不裁剪）。
    /// selectedInstances 为 nil 时使用人物模型的全部实例；
    /// 传入实例编号时使用人物模型，编号来自 `instanceInfos(from:)`。
    /// 传入空集合表示当前帧没有匹配主体。
    public func segmentedImage(
        from cgImage: CGImage,
        selectedInstances: IndexSet? = nil
    ) throws -> CGImage {
        if let selectedInstances {
            return try segmentedImage(
                from: cgImage,
                source: .person,
                selectedInstances: selectedInstances
            )
        }
        return try segmentedImage(from: cgImage, source: .person, selectedInstances: nil)
    }

    /// 用指定模型生成抠图。人物管线传入 `.person`，通用前景路径只供
    /// class-agnostic 的主体提取调用。
    public func segmentedImage(
        from cgImage: CGImage,
        source: VisionMaskSource,
        selectedInstances: IndexSet? = nil
    ) throws -> CGImage {
        let (observation, handler) = try performObservation(from: cgImage, source: source)
        if let selectedInstances, selectedInstances.isEmpty {
            let extent = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            let clear = CIImage(color: CIColor.clear).cropped(to: extent)
            guard let output = context.createCGImage(clear, from: extent) else {
                throw PersonSegmenterError.renderFailed
            }
            return output
        }
        let selected = selectedInstances ?? observation.allInstances
        guard !selected.isEmpty else { throw PersonSegmenterError.noSubject }
        guard let buffer = try? observation.generateMaskedImage(
            ofInstances: selected,
            from: handler,
            croppedToInstancesExtent: false
        ) else {
            throw PersonSegmenterError.noSubject
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let output = context.createCGImage(ci, from: ci.extent) else {
            throw PersonSegmenterError.renderFailed
        }
        return output
    }

    private func performObservation(
        from cgImage: CGImage,
        source: VisionMaskSource
    ) throws -> (VNInstanceMaskObservation, VNImageRequestHandler) {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let observation: VNInstanceMaskObservation?
        switch source {
        case .person:
            let request = VNGeneratePersonInstanceMaskRequest()
            try handler.perform([request])
            observation = request.results?.first
        case .foreground:
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            observation = request.results?.first
        }
        guard let observation else {
            throw PersonSegmenterError.noSubject
        }
        return (observation, handler)
    }

    /// 保留旧的单参数调用，照片提取默认保留画面中的全部人物。
    public func segmentedImage(from cgImage: CGImage) throws -> CGImage {
        try segmentedImage(from: cgImage, selectedInstances: nil)
    }

    private func instanceInfos(
        in observation: VNInstanceMaskObservation,
        from handler: VNImageRequestHandler
    ) -> [ForegroundInstanceInfo] {
        observation.allInstances.compactMap { instance -> ForegroundInstanceInfo? in
            guard let mask = try? observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: instance),
                from: handler
            ),
                  let stats = maskStatistics(mask) else { return nil }
            return ForegroundInstanceInfo(
                index: instance,
                area: stats.area,
                boundingBox: stats.boundingBox,
                center: stats.center,
                maskSignature: stats.maskSignature
            )
        }
        .sorted { $0.area > $1.area }
    }

    /// 遍历实例掩码像素，统计各实例面积，返回面积最大的实例索引（0 = 背景）
    private func largestInstanceIndex(
        in observation: VNInstanceMaskObservation,
        from handler: VNImageRequestHandler
    ) -> Int {
        instanceInfos(in: observation, from: handler).first?.index ?? 0
    }

    private func matchInstances(
        _ infos: [ForegroundInstanceInfo],
        to targetBoxes: [CGRect]
    ) -> IndexSet {
        var used = Set<Int>()
        var result = IndexSet()
        for target in targetBoxes {
            guard let best = infos
                .filter({ !used.contains($0.index) })
                .max(by: { matchScore($0.boundingBox, target) < matchScore($1.boundingBox, target) })
            else { continue }
            guard matchScore(best.boundingBox, target) >= 0.18 else { continue }
            used.insert(best.index)
            result.insert(best.index)
        }
        return result
    }

    private func matchScore(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let unionArea = lhs.union(rhs).width * lhs.union(rhs).height
        let iou = unionArea > 0 ? Double(intersectionArea / unionArea) : 0
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        let distance = min(1, Double(sqrt(dx * dx + dy * dy) / 1.41421356237))
        return iou * 0.72 + max(0, 1 - distance) * 0.28
    }

    /// 为每个实例生成与原图同尺寸的二值 mask，再从 mask 的前景像素计算面积和包围盒。
    /// 这样不依赖低分辨率 instanceMask 的 label 编码和 row stride。
    private func maskStatistics(
        _ maskBuffer: CVPixelBuffer
    ) -> (area: Int, boundingBox: CGRect, center: CGPoint, maskSignature: [UInt8])? {
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(maskBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(maskBuffer)
        let height = CVPixelBufferGetHeight(maskBuffer)
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        let format = CVPixelBufferGetPixelFormatType(maskBuffer)
        let bytesPerPixel = max(1, bytesPerRow / width)
        var area = 0
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var totalX = 0.0
        var totalY = 0.0
        let signatureDimension = 32
        var maskSignature = [UInt8](repeating: 0, count: signatureDimension * signatureDimension)

        for y in 0..<height {
            for x in 0..<width {
                let byteOffset = y * bytesPerRow + x * bytesPerPixel
                guard maskPixelIsForeground(
                    base: base,
                    byteOffset: byteOffset,
                    format: format,
                    bytesPerPixel: bytesPerPixel
                ) else { continue }
                area += 1
                totalX += Double(x)
                totalY += Double(y)
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                let signatureX = min(signatureDimension - 1, x * signatureDimension / width)
                let signatureY = min(signatureDimension - 1, y * signatureDimension / height)
                maskSignature[signatureY * signatureDimension + signatureX] = 1
            }
        }

        guard area > 0, maxX >= minX, maxY >= minY else { return nil }
        return (
            area: area,
            boundingBox: CGRect(
                x: CGFloat(minX) / CGFloat(width),
                y: CGFloat(minY) / CGFloat(height),
                width: CGFloat(maxX - minX + 1) / CGFloat(width),
                height: CGFloat(maxY - minY + 1) / CGFloat(height)
            ),
            center: CGPoint(
                x: CGFloat(totalX / Double(area)) / CGFloat(width),
                y: CGFloat(totalY / Double(area)) / CGFloat(height)
            ),
            maskSignature: maskSignature
        )
    }

    private func maskCoverage(
        _ maskBuffer: CVPixelBuffer,
        polygon: [CGPoint]
    ) -> (coverage: Double, intersectionPixels: Int)? {
        guard polygon.count >= 3 else { return nil }
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(maskBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(maskBuffer)
        let height = CVPixelBufferGetHeight(maskBuffer)
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        let format = CVPixelBufferGetPixelFormatType(maskBuffer)
        let bytesPerPixel = max(1, bytesPerRow / width)
        var visible = 0
        var inside = 0
        for y in 0..<height {
            for x in 0..<width {
                let byteOffset = y * bytesPerRow + x * bytesPerPixel
                guard maskPixelIsForeground(
                    base: base,
                    byteOffset: byteOffset,
                    format: format,
                    bytesPerPixel: bytesPerPixel
                ) else { continue }
                visible += 1
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(width),
                    // Vision's scaled mask shares the CGImage pixel order
                    // used by the picker: row zero is the top row.
                    y: (CGFloat(y) + 0.5) / CGFloat(height)
                )
                if pointIsInsidePolygon(point, polygon: polygon) {
                    inside += 1
                }
            }
        }
        guard visible > 0 else { return nil }
        return (Double(inside) / Double(visible), inside)
    }

    private func pointIsInsidePolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let denominator = previous.y - current.y
            if (current.y > point.y) != (previous.y > point.y),
               abs(denominator) > 0.000001 {
                let x = (previous.x - current.x) * (point.y - current.y)
                    / denominator + current.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private func maskPixelIsForeground(
        base: UnsafeMutableRawPointer,
        byteOffset: Int,
        format: OSType,
        bytesPerPixel: Int
    ) -> Bool {
        switch format {
        case kCVPixelFormatType_OneComponent8:
            return base.load(fromByteOffset: byteOffset, as: UInt8.self) > 8
        case kCVPixelFormatType_OneComponent32Float:
            let value = base.load(fromByteOffset: byteOffset, as: Float.self)
            return value.isFinite && value > 0.05
        default:
            switch bytesPerPixel {
            case 1:
                return base.load(fromByteOffset: byteOffset, as: UInt8.self) > 8
            case 2:
                return base.load(fromByteOffset: byteOffset, as: UInt16.self) > 128
            default:
                return base.load(fromByteOffset: byteOffset, as: UInt32.self) > 0
            }
        }
    }
}
