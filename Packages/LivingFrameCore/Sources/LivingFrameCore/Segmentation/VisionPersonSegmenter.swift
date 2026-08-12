import CoreImage
import Foundation
import Vision

public enum PersonSegmenterError: Error {
    case noSubject
    case renderFailed
}

/// 单帧主体抠图（iOS 17+ / macOS 14+）
/// 使用与 iOS 相册「长按抠主体」相同的引擎：VNGenerateForegroundInstanceMaskRequest
/// （泛化前景实例掩码），相比人物专用掩码质量更稳、边缘更好。
public struct VisionPersonSegmenter {
    public init() {}

    /// 输出带透明通道的主体图（保留原始帧尺寸，不裁剪）
    public func segmentedImage(from cgImage: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw PersonSegmenterError.noSubject
        }
        // 取面积最大的实例作为主体（与相册默认选中主主体的行为一致）
        let largestIndex = largestInstanceIndex(in: observation)
        let selected: IndexSet
        if largestIndex > 0 {
            selected = IndexSet(integer: largestIndex)
        } else {
            // 面积统计失败时退化为全部实例
            selected = observation.allInstances
        }
        guard let buffer = try? observation.generateMaskedImage(
            ofInstances: selected,
            from: handler,
            croppedToInstancesExtent: false
        ) else {
            throw PersonSegmenterError.noSubject
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let output = context.createCGImage(ci, from: ci.extent) else {
            throw PersonSegmenterError.renderFailed
        }
        return output
    }

    /// 遍历实例掩码像素，统计各实例面积，返回面积最大的实例索引（0 = 背景）
    private func largestInstanceIndex(in observation: VNInstanceMaskObservation) -> Int {
        let maskBuffer = observation.instanceMask
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(maskBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(maskBuffer)
        let height = CVPixelBufferGetHeight(maskBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        let format = CVPixelBufferGetPixelFormatType(maskBuffer)
        var areas: [Int: Int] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let index: Int
                switch format {
                case kCVPixelFormatType_OneComponent8:
                    index = Int(base.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self))
                default:
                    // OneComponent32Float 等：按 4 字节读
                    index = Int(base.load(fromByteOffset: y * bytesPerRow + x * 4, as: Float.self))
                }
                if index > 0 {
                    areas[index, default: 0] += 1
                }
            }
        }
        return areas.max(by: { $0.value < $1.value })?.key ?? 0
    }
}
