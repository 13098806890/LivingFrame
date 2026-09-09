import CoreGraphics
import Foundation
import ImageIO
import LivingFrameCore

/// 把素材处理管线与 AppState 的界面状态更新分开。
/// AppState 只负责展示进度、错误和把结果写入素材库。
enum MediaProcessingService {
    static func extractVideo(
        at url: URL,
        name: String,
        maxDimension: CGFloat,
        maxFPS: Double,
        startTime: TimeInterval,
        maxDuration: TimeInterval,
        stillOrientation: CGImagePropertyOrientation,
        progress: @escaping (VideoSegmentationPipeline.ProgressInfo) -> Void
    ) async throws -> SegmentedClip {
        try await VideoSegmentationPipeline().segmentVideo(
            at: url,
            name: name,
            maxDimension: maxDimension,
            maxFPS: maxFPS,
            startTime: startTime,
            maxDuration: maxDuration,
            stillOrientation: stillOrientation,
            progress: progress
        )
    }

    static func extractPhoto(
        from image: CGImage,
        name: String,
        maxDimension: CGFloat
    ) async throws -> SegmentedClip {
        try await Task.detached(priority: .userInitiated) {
            try VideoSegmentationPipeline().segmentPhoto(
                from: image,
                name: name,
                maxDimension: maxDimension
            )
        }.value
    }
}
