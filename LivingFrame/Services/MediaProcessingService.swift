import CoreGraphics
import Foundation
import ImageIO
import LivingFrameCore

/// 把素材处理管线与 AppState 的界面状态更新分开。
/// AppState 只负责展示进度、错误和把结果写入素材库。
enum MediaProcessingService {
    static func analyzeVideo(
        at url: URL,
        maxDimension: CGFloat,
        maxFPS: Double,
        startTime: TimeInterval,
        maxDuration: TimeInterval,
        stillOrientation: CGImagePropertyOrientation,
        initialSelectionRegion: [CGPoint]? = nil,
        progress: @escaping (VideoSegmentationPipeline.ProgressInfo) -> Void
    ) async throws -> VideoSegmentationAnalysis {
        try await VideoSegmentationPipeline().analyzeVideo(
            at: url,
            maxDimension: maxDimension,
            maxFPS: maxFPS,
            startTime: startTime,
            maxDuration: maxDuration,
            stillOrientation: stillOrientation,
            initialSelectionRegion: initialSelectionRegion,
            progress: progress
        )
    }

    static func extractVideo(
        at url: URL,
        name: String,
        algorithm: SegmentationAlgorithm = .foreground,
        maxDimension: CGFloat,
        maxFPS: Double,
        startTime: TimeInterval,
        maxDuration: TimeInterval,
        stillOrientation: CGImagePropertyOrientation,
        analysis: VideoSegmentationAnalysis? = nil,
        selectedSubjectIDs: Set<Int>? = nil,
        selectionRegion: [CGPoint]? = nil,
        progress: @escaping (VideoSegmentationPipeline.ProgressInfo) -> Void
    ) async throws -> SegmentedClip {
        try await VideoSegmentationPipeline().segmentVideo(
            at: url,
            name: name,
            algorithm: algorithm,
            maxDimension: maxDimension,
            maxFPS: maxFPS,
            startTime: startTime,
            maxDuration: maxDuration,
            stillOrientation: stillOrientation,
            analysis: analysis,
            selectedSubjectIDs: selectedSubjectIDs,
            selectionRegion: selectionRegion,
            progress: progress
        )
    }

    static func extractPhoto(
        from image: CGImage,
        name: String,
        algorithm: SegmentationAlgorithm = .foreground,
        selectionRegion: [CGPoint]? = nil,
        maxDimension: CGFloat
    ) async throws -> SegmentedClip {
        try await Task.detached(priority: .userInitiated) {
            try VideoSegmentationPipeline().segmentPhoto(
                from: image,
                name: name,
                algorithm: algorithm,
                selectionRegion: selectionRegion,
                maxDimension: maxDimension
            )
        }.value
    }
}
