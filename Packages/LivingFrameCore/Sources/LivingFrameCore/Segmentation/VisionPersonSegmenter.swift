import CoreImage
import Foundation
import Vision

public enum PersonSegmenterError: Error {
    case noSubject
    case renderFailed
}

/// 单帧人物实例抠图（iOS 17+ / macOS 14+）
public struct VisionPersonSegmenter {
    public init() {}

    /// 输出带透明通道的人物图（保留原始帧尺寸，不裁剪）
    public func segmentedImage(from cgImage: CGImage) throws -> CGImage {
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw PersonSegmenterError.noSubject
        }
        guard let buffer = try? observation.generateMaskedImage(
            ofInstances: observation.allInstances,
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
}
