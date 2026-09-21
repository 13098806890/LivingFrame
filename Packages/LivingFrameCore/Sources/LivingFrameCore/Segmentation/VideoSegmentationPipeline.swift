import AVFoundation
import CoreImage
import CoreGraphics
import Foundation
import Vision

public enum SegmentationError: Error {
    case noVideoTrack
    case readerUnavailable
    case noFrames
    case cancelled
}

/// 视频分析阶段得到的主体轨迹。track ID 是本次分析内稳定的主体 ID，
/// 不代表 Vision 在单帧返回的实例编号。
public struct VideoSubjectTrack: Identifiable {
    public let id: Int
    public let frameCount: Int
    public let firstFrame: Int
    public let lastFrame: Int
    public let averageArea: Double
    /// 代表帧上的归一化包围盒，坐标原点在图像左上角。
    public let previewBoundingBox: CGRect?
    /// 代表帧中该轨迹的透明预览，用于让用户能直接辨认主体。
    public let previewImage: CGImage?

    public init(
        id: Int,
        frameCount: Int,
        firstFrame: Int,
        lastFrame: Int,
        averageArea: Double,
        previewBoundingBox: CGRect?,
        previewImage: CGImage? = nil
    ) {
        self.id = id
        self.frameCount = frameCount
        self.firstFrame = firstFrame
        self.lastFrame = lastFrame
        self.averageArea = averageArea
        self.previewBoundingBox = previewBoundingBox
        self.previewImage = previewImage
    }
}

/// 用于调试主体匹配的逐帧可视化数据。image 是分析阶段生成的低分辨率缩略图，
/// instanceContours 使用左上角为原点的归一化坐标，避免检查器再次执行 Vision。
public struct VideoSegmentationFrameDebug: Identifiable {
    public let id: Int
    public let image: CGImage
    public let instanceContours: [Int: [CGPoint]]
    public let instanceToTrack: [Int: Int]

    public init(
        id: Int,
        image: CGImage,
        instanceContours: [Int: [CGPoint]],
        instanceToTrack: [Int: Int]
    ) {
        self.id = id
        self.image = image
        self.instanceContours = instanceContours
        self.instanceToTrack = instanceToTrack
    }
}

/// Vision 分析结果。frameAssignments 保存每个处理帧中的“实例编号 → 轨迹 ID”，
/// 第二阶段重新读取同一视频时可据此生成用户选择的主体。
public struct VideoSegmentationAnalysis {
    public let tracks: [VideoSubjectTrack]
    public let frameAssignments: [[Int: Int]]
    /// 每个分析帧的轨迹包围盒，坐标与 `ForegroundInstanceInfo` 一致。
    /// 渲染阶段据此把稳定的前景实例匹配回用户选中的人物轨迹。
    public let frameTrackBoundingBoxes: [[Int: CGRect]]
    public let previewImage: CGImage?
    public let frameDebug: [VideoSegmentationFrameDebug]

    public init(
        tracks: [VideoSubjectTrack],
        frameAssignments: [[Int: Int]],
        frameTrackBoundingBoxes: [[Int: CGRect]] = [],
        previewImage: CGImage?,
        frameDebug: [VideoSegmentationFrameDebug] = []
    ) {
        self.tracks = tracks
        self.frameAssignments = frameAssignments
        self.frameTrackBoundingBoxes = frameTrackBoundingBoxes
        self.previewImage = previewImage
        self.frameDebug = frameDebug
    }
}

private struct SubjectTrackState {
    let id: Int
    var lastBoundingBox: CGRect
    var lastCenter: CGPoint
    var lastFrame: Int
    var firstFrame: Int
    var frameCount: Int
    var areaTotal: Double
    var previewBoundingBox: CGRect?
    var lastMaskSignature: [UInt8]
    var lastInstanceIndex: Int?
    var pendingInstanceIndex: Int?
    var pendingInstanceCount: Int
}

/// 视频抠图管线：逐帧读流 → 实例掩码抠图 → 透明 PNG 序列 → 提取音频
public struct VideoSegmentationPipeline {
    public struct ProgressInfo {
        public let fraction: Double
        public let frameIndex: Int
        public let totalFrames: Int
    }

    public typealias ProgressHandler = (ProgressInfo) -> Void

    /// preferredTransform → CGImagePropertyOrientation（0/90/180/270 + 镜像）
    static func orientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let mirrored = (transform.a * transform.d - transform.b * transform.c) < 0
        var degrees = (atan2(transform.b, transform.a) * 180 / .pi)
            .truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        switch Int(degrees.rounded()) {
        case 90: return mirrored ? .rightMirrored : .right
        case 180: return mirrored ? .downMirrored : .down
        case 270: return mirrored ? .leftMirrored : .left
        default: return mirrored ? .upMirrored : .up
        }
    }

    static func usesStillOrientation(for transform: CGAffineTransform) -> Bool {
        abs(transform.a - 1) < 0.001
            && abs(transform.b) < 0.001
            && abs(transform.c) < 0.001
            && abs(transform.d - 1) < 0.001
    }

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    public init() {}

    /// 先完整分析视频中的前景主体轨迹，不写入素材库。
    /// 这一步用于让用户在动态素材生成前选择保留一个或多个主体。
    public func analyzeVideo(
        at url: URL,
        maxDimension: CGFloat = 1280,
        maxFPS: Double = 30,
        startTime: TimeInterval = 0,
        maxDuration: TimeInterval = 5,
        stillOrientation: CGImagePropertyOrientation = .up,
        initialSelectionRegion: [CGPoint]? = nil,
        progress: ProgressHandler? = nil,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async throws -> VideoSegmentationAnalysis {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SegmentationError.noVideoTrack
        }
        let sourceDuration = try await asset.load(.duration)
        let sourceSeconds = max(sourceDuration.seconds, 0.1)
        let safeStartTime = min(
            max(startTime.isFinite ? startTime : 0, 0),
            max(sourceSeconds - 0.1, 0)
        )
        let availableSeconds = max(sourceSeconds - safeStartTime, 0.1)
        let requestedMaxDuration = maxDuration.isFinite && maxDuration > 0
            ? maxDuration
            : availableSeconds
        let duration = CMTime(
            seconds: min(availableSeconds, requestedMaxDuration),
            preferredTimescale: 600
        )
        let frameRate = try await track.load(.nominalFrameRate)
        let preferredTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let safeFrameRate = frameRate.isFinite && frameRate > 0 ? Double(frameRate) : 30
        let safeMaxFPS = maxFPS.isFinite && maxFPS > 0 ? maxFPS : safeFrameRate
        let frameStep = max(1, Int((safeFrameRate / safeMaxFPS).rounded()))
        let outputFPS = max(1, safeFrameRate / Double(frameStep))
        let timeRange = CMTimeRange(
            start: CMTime(seconds: safeStartTime, preferredTimescale: 600),
            duration: duration
        )
        LogStore.log(
            "xdz.subject.analysis.start url=\(url.lastPathComponent) duration=\(duration.seconds) "
                + "size=\(Int(naturalSize.width))x\(Int(naturalSize.height)) "
                + "maxDimension=\(maxDimension) maxFPS=\(safeMaxFPS) frameStep=\(frameStep) outputFPS=\(outputFPS)"
        )

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SegmentationError.readerUnavailable }
        reader.add(output)
        reader.timeRange = timeRange
        guard reader.startReading() else { throw SegmentationError.readerUnavailable }

        let totalFrames = max(1, Int((duration.seconds * outputFPS).rounded(.up)))
        let segmenter = VisionPersonSegmenter()
        let initialShape = normalizedAbsoluteSelectionShape(from: initialSelectionRegion)
        var states: [Int: SubjectTrackState] = [:]
        var nextTrackID = 0
        var assignments: [[Int: Int]] = []
        var trackBoundingBoxes: [[Int: CGRect]] = []
        var previewImage: CGImage?
        var previewInstanceCount = 0
        var previewBoxesByTrack: [Int: CGRect] = [:]
        var previewImagesByTrack: [Int: CGImage] = [:]
        var frameDebug: [VideoSegmentationFrameDebug] = []
        /// 预圈选确定的轨迹种子。启用后，后续帧不再创建圈外的新轨迹。
        var regionSeedTrackIDs: Set<Int>?
        var didApplyInitialRegion = false
        var sampleIndex = 0
        var processedFrameIndex = 0

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() || Task.isCancelled {
                reader.cancelReading()
                throw SegmentationError.cancelled
            }
            let process = sampleIndex % frameStep == 0
            sampleIndex += 1
            guard process else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                assignments.append([:])
                trackBoundingBoxes.append([:])
                processedFrameIndex += 1
                continue
            }
            let source = CIImage(cvPixelBuffer: pixelBuffer)
            let derived = Self.orientation(from: preferredTransform)
            let oriented: CIImage
            if Self.usesStillOrientation(for: preferredTransform) {
                oriented = stillOrientation == .up ? source : source.oriented(stillOrientation)
            } else {
                oriented = source.oriented(derived)
            }
            let scale = min(1.0, maxDimension / max(oriented.extent.width, oriented.extent.height))
            let input = scale < 1.0
                ? oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : oriented
            guard let cgImage = context.createCGImage(input, from: input.extent.integral) else {
                assignments.append([:])
                trackBoundingBoxes.append([:])
                processedFrameIndex += 1
                continue
            }

            let infos: [ForegroundInstanceInfo]
            do {
                // The first frame is the only frame for which the user has
                // drawn an absolute region. Use the actual instance mask, so
                // nearby people do not become tracks just because their
                // boundingBox also covers the full canvas.
                if processedFrameIndex == 0, let initialShape {
                    let filtered = (try? segmenter.instanceInfos(
                        from: cgImage,
                        source: .person,
                        intersecting: initialShape,
                        minimumCoverage: 0.20,
                        minimumIntersectionPixels: 24
                    )) ?? []
                    // 圈选一旦启用就严格限制候选集。即使这一帧没有
                    // 命中，也不能退回整帧检测，否则圈外人物会重新出现。
                    infos = filtered
                    didApplyInitialRegion = true
                    LogStore.log(
                        "xdz.subject.analysis.initialRegion filtered=\(filtered.count) applied=true"
                    )
                } else {
                    infos = try segmenter.instanceInfos(from: cgImage)
                }
            } catch {
                LogStore.log("xdz.subject.analysis.frame=\(processedFrameIndex) instances=0 error=\(error)")
                assignments.append([:])
                trackBoundingBoxes.append([:])
                processedFrameIndex += 1
                progress?(ProgressInfo(
                    fraction: min(1, Double(processedFrameIndex) / Double(totalFrames)),
                    frameIndex: processedFrameIndex,
                    totalFrames: totalFrames
                ))
                continue
            }

            let mapping = assignTracks(
                infos: infos,
                frameIndex: processedFrameIndex,
                states: &states,
                nextTrackID: &nextTrackID,
                maxGapFrames: max(8, Int((outputFPS * 0.5).rounded())),
                allowedTrackIDs: regionSeedTrackIDs
            )
            if processedFrameIndex == 0, didApplyInitialRegion {
                regionSeedTrackIDs = Set(mapping.values)
                LogStore.log(
                    "xdz.subject.analysis.initialRegion.seedTracks="
                        + "\(regionSeedTrackIDs?.sorted().map(String.init).joined(separator: ",") ?? "none")"
                )
            }
            assignments.append(mapping)
            var boxesForTracks: [Int: CGRect] = [:]
            for info in infos {
                if let trackID = mapping[info.index] {
                    boxesForTracks[trackID] = info.boundingBox
                }
            }
            trackBoundingBoxes.append(boxesForTracks)
            let instanceSummary = infos
                .map { "\($0.index):\($0.area)" }
                .joined(separator: ",")
            let trackSummary = mapping.values
                .sorted()
                .map(String.init)
                .joined(separator: ",")
            let mappingSummary = mapping
                .sorted { $0.key < $1.key }
                .map { "\($0.key)->\($0.value)" }
                .joined(separator: ",")
            LogStore.log(
                "xdz.subject.analysis.frame=\(processedFrameIndex) "
                    + "instances=\(instanceSummary) tracks=\(trackSummary) mapping=\(mappingSummary)"
            )
            if let debugImage = debugThumbnail(from: cgImage) {
                let contours = infos.reduce(into: [Int: [CGPoint]]()) { result, info in
                    let contour = maskContour(from: info.maskSignature)
                    if contour.count >= 3 {
                        result[info.index] = contour
                    }
                }
                frameDebug.append(VideoSegmentationFrameDebug(
                    id: processedFrameIndex,
                    image: debugImage,
                    instanceContours: contours,
                    instanceToTrack: mapping
                ))
            }
            if infos.count > previewInstanceCount {
                previewInstanceCount = infos.count
                previewImage = cgImage
                previewBoxesByTrack = [:]
                previewImagesByTrack = [:]
                for info in infos {
                    guard let trackID = mapping[info.index] else { continue }
                    previewBoxesByTrack[trackID] = info.boundingBox
                    if let subjectPreview = try? segmenter.segmentedImage(
                        from: cgImage,
                        selectedInstances: IndexSet(integer: info.index)
                    ) {
                        previewImagesByTrack[trackID] = subjectPreview
                        if let visibleBounds = AlphaSubjectBounds.visiblePixelBounds(in: subjectPreview) {
                            previewBoxesByTrack[trackID] = CGRect(
                                x: visibleBounds.minX / CGFloat(subjectPreview.width),
                                y: 1 - visibleBounds.maxY / CGFloat(subjectPreview.height),
                                width: visibleBounds.width / CGFloat(subjectPreview.width),
                                height: visibleBounds.height / CGFloat(subjectPreview.height)
                            )
                        }
                    }
                }
            }
            processedFrameIndex += 1
            progress?(ProgressInfo(
                fraction: min(1, Double(processedFrameIndex) / Double(totalFrames)),
                frameIndex: processedFrameIndex,
                totalFrames: totalFrames
            ))
        }
        reader.cancelReading()

        if isCancelled() || Task.isCancelled { throw SegmentationError.cancelled }

        let minimumStableFrames = max(3, Int((outputFPS * 0.15).rounded()))
        let tracks = states.values
            .filter { $0.frameCount >= minimumStableFrames }
            .map {
                VideoSubjectTrack(
                    id: $0.id,
                    frameCount: $0.frameCount,
                    firstFrame: $0.firstFrame,
                    lastFrame: $0.lastFrame,
                    averageArea: $0.frameCount > 0 ? $0.areaTotal / Double($0.frameCount) : 0,
                    previewBoundingBox: previewBoxesByTrack[$0.id] ?? $0.previewBoundingBox,
                    previewImage: previewImagesByTrack[$0.id]
                )
            }
            .sorted { lhs, rhs in
                if lhs.firstFrame != rhs.firstFrame { return lhs.firstFrame < rhs.firstFrame }
                return lhs.id < rhs.id
            }
        let trackSummary = tracks
            .map { "\($0.id):frames=\($0.frameCount):first=\($0.firstFrame):last=\($0.lastFrame)" }
            .joined(separator: ",")
        LogStore.log(
            "xdz.subject.analysis.done tracks=\(trackSummary) "
                + "stableMinFrames=\(minimumStableFrames) previewInstances=\(previewInstanceCount)"
        )
        progress?(ProgressInfo(
            fraction: 1,
            frameIndex: processedFrameIndex,
            totalFrames: max(totalFrames, processedFrameIndex)
        ))
        return VideoSegmentationAnalysis(
            tracks: tracks,
            frameAssignments: assignments,
            frameTrackBoundingBoxes: trackBoundingBoxes,
            previewImage: previewImage,
            frameDebug: frameDebug
        )
    }

    @discardableResult
    public func segmentVideo(
        at url: URL,
        name: String = NSLocalizedString("素材", comment: "Default clip name"),
        algorithm: SegmentationAlgorithm = .visionPerson,
        maxDimension: CGFloat = 1280,
        maxFPS: Double = 30,
        startTime: TimeInterval = 0,
        maxDuration: TimeInterval = 5,
        stillOrientation: CGImagePropertyOrientation = .up,
        analysis: VideoSegmentationAnalysis? = nil,
        selectedSubjectIDs: Set<Int>? = nil,
        selectionRegion: [CGPoint]? = nil,
        sam2Prompt: SAM2Prompt? = nil,
        progress: ProgressHandler? = nil,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async throws -> SegmentedClip {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            LogStore.log("segmentVideo: no video track \(url.lastPathComponent)")
            throw SegmentationError.noVideoTrack
        }
        let sourceDuration = try await asset.load(.duration)
        let sourceSeconds = max(sourceDuration.seconds, 0.1)
        let safeStartTime = min(
            max(startTime.isFinite ? startTime : 0, 0),
            max(sourceSeconds - 0.1, 0)
        )
        let availableSeconds = max(sourceSeconds - safeStartTime, 0.1)
        let requestedMaxDuration = maxDuration.isFinite && maxDuration > 0
            ? maxDuration
            : availableSeconds
        let duration = CMTime(
            seconds: min(availableSeconds, requestedMaxDuration),
            preferredTimescale: 600
        )
        let frameRate = try await track.load(.nominalFrameRate)
        // AVAssetReader 输出的是未旋转的原始像素，需应用 preferredTransform 恢复拍摄方向
        let preferredTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        // 源帧率异常（0/NaN）时按 30fps 兜底，避免抽帧计算产生 NaN
        let safeFrameRate = frameRate.isFinite && frameRate > 0 ? Double(frameRate) : 30
        // 抽帧步长：目标帧率低于源帧率时，隔 N 帧处理 1 帧
        let frameStep = max(1, Int((safeFrameRate / maxFPS).rounded()))
        let outputFPS = max(1, safeFrameRate / Double(frameStep))
        let timeRange = CMTimeRange(
            start: CMTime(seconds: safeStartTime, preferredTimescale: 600),
            duration: duration
        )
        LogStore.log("segmentVideo durationLimit: source=\(sourceSeconds)s start=\(safeStartTime)s processed=\(duration.seconds)s max=\(maxDuration)s")
        LogStore.log("segmentVideo algorithm=\(algorithm.rawValue)")
        LogStore.log("segmentVideo input: name=\(url.lastPathComponent) size=\(Int(naturalSize.width))x\(Int(naturalSize.height)) duration=\(duration.seconds)s fps=\(safeFrameRate) step=\(frameStep) outputFPS=\(outputFPS) transform=\(preferredTransform) stillOrientation=\(stillOrientation.rawValue) derivedOrientation=\(preferredTransform.isIdentity ? (stillOrientation == .down ? "down(180°)" : "none") : "\(Self.orientation(from: preferredTransform).rawValue)")" )

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SegmentationError.readerUnavailable }
        reader.add(output)
        reader.timeRange = timeRange
        guard reader.startReading() else { throw SegmentationError.readerUnavailable }

        let clipID = UUID().uuidString
        let folder = try FrameCache.shared.makeClipFolder(id: clipID)
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let totalFrames = max(1, Int((duration.seconds * outputFPS).rounded(.up)))

        let segmenter = VisionPersonSegmenter()
        // Algorithm entry points:
        // - .foreground: original class-agnostic foreground extraction.
        // - .visionPerson: existing Vision person-instance analysis/selection.
        // - .sam2: hybrid prompt-driven extraction. SAM2 identifies the object
        //   under the user's point; Vision renders the complete person mask.
        let selectionShape = normalizedSelectionShape(from: selectionRegion)
        let absoluteSelectionShape = normalizedAbsoluteSelectionShape(from: selectionRegion)
        let initialSAM2Prompt = sam2Prompt
            ?? absoluteSelectionShape.flatMap { shape in
                SAM2Segmenter.promptPoint(in: shape).map {
                    SAM2Prompt(foregroundPoints: [$0])
                }
            }
        let sam2: SAM2Segmenter?
        if algorithm == .sam2 {
            sam2 = try SAM2Segmenter.bundled()
            LogStore.log("xdz.sam2.render.loaded=true promptRegion=\(absoluteSelectionShape != nil)")
        } else {
            sam2 = nil
        }
        if let selectedSubjectIDs {
            LogStore.log(
                "xdz.subject.render.start name=\(name) selectedTracks=\(selectedSubjectIDs.sorted().map(String.init).joined(separator: ",")) "
                    + "analysisFrames=\(analysis?.frameAssignments.count ?? 0) "
                    + "hasSelectionRegion=\(selectionRegion != nil)"
            )
        }
        var index = 0
        var sampleIndex = 0
        var analysisFrameIndex = 0
        var firstSize: (width: Int, height: Int)?
        var skippedNoSubject = 0
        var skippedNoImage = 0
        /// 上一帧分割结果（时域补全用，只存原始帧避免累计拖影）
        var prevMaskedImage: CIImage?
        /// 上一帧人物模型结果。前景模型负责连续边缘，人物模型只作为
        /// 选中主体的身份遮罩；人物模型短暂漏检时沿用这一帧。
        var prevPersonMask: CIImage?
        var previousRefinedBounds: CGRect?
        let sequenceHandler = VNSequenceRequestHandler()
        var objectTracker: VNTrackObjectRequest?
        var trackerPrediction: CGRect?
        var trackerConfidence = 0.0
        let lassoSourceBounds = normalizedBounds(of: absoluteSelectionShape)
        let canFollowSingleSubjectLasso = selectedSubjectIDs?.count == 1
            && absoluteSelectionShape != nil
            && lassoSourceBounds != nil
        var sam2PromptPoint = initialSAM2Prompt?.primaryForegroundPoint
            ?? CGPoint(x: 0.5, y: 0.5)
        var activeSAM2Prompt = initialSAM2Prompt ?? SAM2Prompt(
            foregroundPoints: [sam2PromptPoint]
        )
        /// Keep the SAM2 semantic refresh close to 30 Hz. At the default
        /// 30 fps output this runs SAM2 on every processed frame; at 60 fps it
        /// refreshes every other processed frame. Lower-FPS exports naturally
        /// refresh every available frame. This intentionally favors arm/hand
        /// motion stability over the old ~6 Hz refresh cadence.
        let sam2RefreshRate = 30.0
        let sam2RefreshInterval = max(1, Int((outputFPS / sam2RefreshRate).rounded()))
        var sam2LastMask: CIImage?
        var sam2LastBounds: CGRect?
        var hybridPersonCenter: CGPoint?

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() || Task.isCancelled {
                reader.cancelReading()
                LogStore.log("segmentVideo: user cancelled")
                throw SegmentationError.cancelled
            }
            let process = sampleIndex % frameStep == 0
            sampleIndex += 1
            guard process else { continue }
            let currentAnalysisFrameIndex = analysisFrameIndex
            analysisFrameIndex += 1
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                skippedNoImage += 1
                continue
            }
            let source = CIImage(cvPixelBuffer: pixelBuffer)
            // 方向修正：优先用视频轨旋转元数据；若变换不含旋转（identity、仅平移或浮点误差导致
            // 推导为 up/down），则以静态图 EXIF 方向为准——Live Photo 的静态图与视频来自同一次
            // 拍摄，方向一致；普通视频不传 stillOrientation（.up）不受影响
            let derived = Self.orientation(from: preferredTransform)
            let oriented: CIImage
            if Self.usesStillOrientation(for: preferredTransform) {
                oriented = stillOrientation == .up
                    ? source
                    : source.oriented(stillOrientation)
            } else {
                oriented = source.oriented(derived)
            }
            // 逐帧日志开销大（1~3 分钟抠图会写几千行），只抽样记录
            if index % 30 == 0 {
                LogStore.log("segmentVideo: frame \(index) derived=\(derived.rawValue) still=\(stillOrientation.rawValue) using=\(oriented.extent.width)x\(oriented.extent.height)")
            }
            let scale = min(1.0, maxDimension / max(oriented.extent.width, oriented.extent.height))
            let input = scale < 1.0
                ? oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : oriented
            guard let cgImage = context.createCGImage(input, from: input.extent.integral) else { continue }

            // 先追踪上一帧主体的大致位置。人物实例掩码随后负责精确轮廓，
            // 追踪结果用于阻止大动作时实例编号突然切换。
            trackerPrediction = nil
            trackerConfidence = 0
            if let objectTracker {
                do {
                    try sequenceHandler.perform([objectTracker], on: cgImage)
                    if let observation = objectTracker.results?.first as? VNDetectedObjectObservation {
                        trackerPrediction = topLeftBounds(from: observation.boundingBox)
                        trackerConfidence = Double(observation.confidence)
                        objectTracker.inputObservation = observation
                        LogStore.log(
                            "xdz.subject.tracker frame=\(index) confidence=\(String(format: "%.3f", trackerConfidence)) "
                                + "bounds=\(String(describing: trackerPrediction))"
                        )
                    }
                } catch {
                    LogStore.log("xdz.subject.tracker frame=\(index) failed=\(error)")
                }
            }

            do {
                var selectedInstances: IndexSet?
                if let analysis, let selectedSubjectIDs {
                    let assignments = currentAnalysisFrameIndex < analysis.frameAssignments.count
                        ? analysis.frameAssignments[currentAnalysisFrameIndex]
                        : [:]
                    let selected = assignments.compactMap { instance, trackID in
                        selectedSubjectIDs.contains(trackID) ? instance : nil
                    }
                    var selectedIndexes = IndexSet()
                    selected.forEach { selectedIndexes.insert($0) }
                    selectedInstances = selectedIndexes
                    if selected.isEmpty {
                        LogStore.log(
                            "xdz.subject.render.frame=\(index) selectedTrackNotVisible=true "
                                + "source=person fallback=previous-mask"
                        )
                    }
                } else {
                    selectedInstances = nil
                }
                let current: CIImage
                var currentHasVisibleSubject = true
                let hasExplicitSubjectSelection = analysis != nil && selectedSubjectIDs != nil
                if algorithm == .sam2 {
                    guard let sam2 else { throw SAM2Error.modelNotFound("bundled SAM2") }
                    let frameImage = CIImage(cgImage: cgImage)
                    let shouldRefresh = sam2LastMask == nil || index % sam2RefreshInterval == 0
                    var maskForFrame: CIImage?
                    if shouldRefresh {
                        // Refresh from the tracked position when available,
                        // instead of blindly using the previous mask's center.
                        if let tracked = trackerPrediction ?? sam2LastBounds {
                            sam2PromptPoint = CGPoint(x: tracked.midX, y: tracked.midY)
                            activeSAM2Prompt.foregroundPoints = [sam2PromptPoint]
                        }

                        if let result = sam2.maskWithScore(for: frameImage, prompt: activeSAM2Prompt),
                           result.score >= 0.30,
                           let candidateBounds = sam2.normalizedBounds(of: result.mask),
                           isStableSAM2Candidate(candidateBounds, previous: sam2LastBounds) {
                            maskForFrame = result.mask
                            sam2LastMask = result.mask
                            sam2LastBounds = candidateBounds
                            sam2PromptPoint = CGPoint(x: candidateBounds.midX, y: candidateBounds.midY)
                            activeSAM2Prompt.foregroundPoints = [sam2PromptPoint]
                            seedSAM2Tracker(
                                bounds: candidateBounds,
                                objectTracker: &objectTracker
                            )
                            LogStore.log(
                                "xdz.sam2.render.frame=\(index) refresh=true "
                                + "interval=\(sam2RefreshInterval) targetHz=\(sam2RefreshRate) "
                                    + "score=\(String(format: "%.3f", result.score)) "
                                    + "bounds=\(candidateBounds)"
                            )
                        } else {
                            LogStore.log(
                                "xdz.sam2.render.frame=\(index) refresh=rejected "
                                    + "previous=\(String(describing: sam2LastBounds))"
                            )
                        }
                    }

                    if maskForFrame == nil,
                       let lastMask = sam2LastMask,
                       let lastBounds = sam2LastBounds {
                        let targetBounds = trackedBounds(trackerPrediction ?? lastBounds) ?? lastBounds
                        maskForFrame = transformedMask(
                            lastMask,
                            from: lastBounds,
                            to: targetBounds,
                            extent: frameImage.extent
                        )
                        sam2PromptPoint = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
                        LogStore.log(
                            "xdz.sam2.render.frame=\(index) refresh=false "
                                + "trackedBounds=\(targetBounds)"
                        )
                    }
                    if let maskForFrame {
                        let sam2Current = applyLuminanceMask(frameImage, with: maskForFrame)
                        let targetBounds = sam2.normalizedBounds(of: maskForFrame) ?? sam2LastBounds
                        // SAM2 supplies identity; Vision supplies the final
                        // silhouette. Do not intersect the two masks here:
                        // SAM2 can select only a shirt/leg region when the
                        // user taps clothing, while Vision can keep the whole
                        // connected person together.
                        if let targetBounds,
                           let hybrid = try? segmenter.segmentedPersonImage(
                               from: cgImage,
                               matching: targetBounds,
                               targetPoint: sam2PromptPoint,
                               previousCenter: hybridPersonCenter
                           ),
                           hybrid.score >= 0.20 {
                            current = CIImage(cgImage: hybrid.image)
                            hybridPersonCenter = hybrid.info.center
                            if let hybridBounds = normalizedVisibleBounds(in: hybrid.image),
                               objectTracker == nil || index % 10 == 0 {
                                seedSAM2Tracker(
                                    bounds: hybridBounds,
                                    objectTracker: &objectTracker
                                )
                            }
                            LogStore.log(
                                "xdz.sam2.render.frame=\(index) hybrid=vision-person "
                                    + "sam2Identity=true score=\(String(format: "%.3f", hybrid.score))"
                            )
                        } else {
                            current = sam2Current
                            LogStore.log("xdz.sam2.render.frame=\(index) hybrid=vision-fallback-sam2")
                        }
                    } else if let previous = prevMaskedImage {
                        current = previous
                        LogStore.log("xdz.sam2.render.frame=\(index) mask=previous")
                    } else {
                        throw PersonSegmenterError.noSubject
                    }
                } else if hasExplicitSubjectSelection {
                    var personMask: CIImage
                    var hasFreshPersonMask = false
                    if selectedInstances?.isEmpty == true {
                        if let previous = prevPersonMask {
                            personMask = previous
                            LogStore.log("xdz.subject.render.frame=\(index) personMask=previous")
                        } else {
                            personMask = CIImage(color: CIColor.clear).cropped(to: CGRect(
                                x: 0,
                                y: 0,
                                width: cgImage.width,
                                height: cgImage.height
                            ))
                            currentHasVisibleSubject = false
                            LogStore.log("xdz.subject.render.frame=\(index) personMask=clear")
                        }
                    } else {
                        let personCGImage = try segmenter.segmentedImage(
                            from: cgImage,
                            source: .person,
                            selectedInstances: selectedInstances
                        )
                        if let candidateBounds = normalizedVisibleBounds(in: personCGImage),
                           AlphaSubjectBounds.visiblePixelBounds(in: personCGImage) != nil {
                            let isAbruptChange = previousRefinedBounds.map {
                                let previousArea = max($0.width * $0.height, 0.0001)
                                let candidateArea = candidateBounds.width * candidateBounds.height
                                let areaRatio = candidateArea / previousArea
                                let centerDelta = sqrt(
                                    pow(candidateBounds.midX - $0.midX, 2)
                                        + pow(candidateBounds.midY - $0.midY, 2)
                                )
                                let suddenFullCanvasExpansion = candidateBounds.width >= 0.98
                                    && candidateBounds.height >= 0.98
                                    && previousArea < 0.85
                                let trackerMismatch = trackerPrediction.map {
                                    let trackerDistance = pointDistance(
                                        CGPoint(x: candidateBounds.midX, y: candidateBounds.midY),
                                        CGPoint(x: $0.midX, y: $0.midY)
                                    )
                                    return trackerConfidence >= 0.30
                                        && trackerDistance > 0.28
                                } ?? false
                                return areaRatio > 1.45
                                    || areaRatio < 0.62
                                    || centerDelta > 0.20
                                    || suddenFullCanvasExpansion
                                    || trackerMismatch
                            } ?? false

                            if isAbruptChange, let previous = prevPersonMask {
                                personMask = previous
                                LogStore.log(
                                    "xdz.subject.render.frame=\(index) personMask=previous-outlier "
                                        + "candidateBounds=\(candidateBounds)"
                                )
                            } else {
                                personMask = CIImage(cgImage: personCGImage)
                                hasFreshPersonMask = true
                                previousRefinedBounds = candidateBounds
                                if objectTracker == nil || index % 10 == 0 {
                                    let trackerSeedBounds = canFollowSingleSubjectLasso
                                        ? (lassoSourceBounds ?? candidateBounds)
                                        : candidateBounds
                                    let observation = VNDetectedObjectObservation(
                                        boundingBox: visionBounds(from: trackerSeedBounds)
                                    )
                                    let tracker = VNTrackObjectRequest(
                                        detectedObjectObservation: observation
                                    )
                                    tracker.trackingLevel = .accurate
                                    objectTracker = tracker
                                    LogStore.log(
                                        "xdz.subject.tracker.seed frame=\(index) bounds=\(trackerSeedBounds)"
                                    )
                                }
                                LogStore.log(
                                    "xdz.subject.render.bounds frame=\(index) value=\(candidateBounds)"
                                )
                            }
                        } else if let previous = prevPersonMask {
                            personMask = previous
                            LogStore.log("xdz.subject.render.frame=\(index) personMask=previous-empty")
                        } else {
                            throw PersonSegmenterError.noSubject
                        }
                    }

                    // 圈选只负责初始主体筛选和追踪器初始化，不再参与渲染阶段的
                    // alpha 裁剪。把首帧圈选范围变成跟随遮罩会把第一次圈选的
                    // 矩形/多边形错误地带到所有后续帧，导致人物移动后只剩原区域。
                    // 当前帧的 Person instance mask 才是每一帧的真实边界。
                    if index == 0, absoluteSelectionShape != nil {
                        LogStore.log(
                            "xdz.subject.render.frame=0 lasso=selection-only "
                                + "reason=no-render-clamp"
                        )
                    }
                    LogStore.log(
                        "xdz.subject.render.frame=\(index) region=track-mask "
                            + "lassoHint=\(selectionShape != nil) "
                            + "freshPerson=\(hasFreshPersonMask)"
                    )

                    // 对人物素材，人物实例 mask 本身就是最终身份和边缘来源。
                    // 再与 class-agnostic foreground mask 相交会在两人相邻、
                    // 头发/手臂细节贴近时额外吃掉像素。
                    current = personMask
                    if hasFreshPersonMask {
                        prevPersonMask = personMask
                    }
                } else {
                    let source: VisionMaskSource = algorithm == .foreground
                        ? .foreground
                        : .person
                    let foreground = try segmenter.segmentedImage(
                        from: cgImage,
                        source: source,
                        selectedInstances: nil
                    )
                    if AlphaSubjectBounds.visiblePixelBounds(in: foreground) != nil {
                        current = CIImage(cgImage: foreground)
                    } else if let previous = prevMaskedImage {
                        current = previous
                        LogStore.log("xdz.subject.render.frame=\(index) maskEmpty=true fallback=previous-mask")
                    } else {
                        current = CIImage(cgImage: foreground)
                        currentHasVisibleSubject = false
                        LogStore.log("xdz.subject.render.frame=\(index) maskEmpty=true fallback=none")
                    }
                }
                // 时域补全：与上一帧原始分割结果做并集（通道取最大）。
                // 逐帧独立分割会偶发漏检（如腿部某帧缺失），并集让漏检帧用上一帧补全。
                // 只与上一帧并集，不累计，避免人物移动产生拖影。
                let output: CIImage
                if hasExplicitSubjectSelection || algorithm == .sam2 {
                    // Vision 已选择主体时 current 是 person mask；SAM2 路径
                    // 则已经是当前帧的 prompt mask。两者都不能再和上一帧
                    // 做并集，否则会把旧帧的错误主体拖回当前帧。
                    output = current
                } else if let prev = prevMaskedImage {
                    output = current.applyingFilter("CIMaximumCompositing", parameters: [
                        kCIInputBackgroundImageKey: prev
                    ])
                } else {
                    output = current
                }
                if currentHasVisibleSubject {
                    prevMaskedImage = current
                }
                guard let outCG = context.createCGImage(output, from: output.extent.integral) else { continue }
                let frameURL = folder.appendingPathComponent(String(format: "%05d.png", index))
                guard writePNG(outCG, to: frameURL) else { continue }
                if firstSize == nil {
                    firstSize = (outCG.width, outCG.height)
                }
                index += 1
                progress?(ProgressInfo(
                    fraction: min(1, Double(index) / Double(totalFrames)),
                    frameIndex: index,
                    totalFrames: totalFrames
                ))
            } catch {
                // 人物暂时出画或被遮挡时保留上一帧，避免把时间轴压短造成跳帧感。
                if let prev = prevMaskedImage,
                   let fallback = context.createCGImage(prev, from: prev.extent.integral) {
                    let frameURL = folder.appendingPathComponent(String(format: "%05d.png", index))
                    if writePNG(fallback, to: frameURL) {
                        LogStore.log("xdz.subject.render.frame=\(index) visionFailed=true fallback=previous-mask")
                        if firstSize == nil {
                            firstSize = (fallback.width, fallback.height)
                        }
                        index += 1
                        progress?(ProgressInfo(
                            fraction: min(1, Double(index) / Double(totalFrames)),
                            frameIndex: index,
                            totalFrames: totalFrames
                        ))
                        continue
                    }
                }
                skippedNoSubject += 1
                LogStore.log("xdz.subject.render.frame=\(index) visionFailed=true fallback=none")
            }
        }

        reader.cancelReading()

        if isCancelled() || Task.isCancelled {
            throw SegmentationError.cancelled
        }

        LogStore.log("segmentVideo output: okFrames=\(index) skippedNoSubject=\(skippedNoSubject) skippedNoImage=\(skippedNoImage) frameSize=\(firstSize?.width ?? 0)x\(firstSize?.height ?? 0)")

        guard index > 0, let firstSize else {
            LogStore.log("segmentVideo failed: 0 valid frames")
            throw SegmentationError.noFrames
        }

        var clip = SegmentedClip(
            id: clipID,
            name: name,
            fps: outputFPS,
            frameCount: index,
            width: firstSize.width,
            height: firstSize.height,
            folderURL: folder
        )

        // Frame count is estimated from duration and can be larger than the
        // samples AVAssetReader actually delivered. Mark frame processing as
        // complete before the optional audio pass so the UI does not appear
        // frozen at the last frame percentage.
        progress?(ProgressInfo(
            fraction: 0.98,
            frameIndex: index,
            totalFrames: max(totalFrames, index)
        ))
        LogStore.log("xdz.subject.render.framesDone frames=\(index) estimated=\(totalFrames) progress=0.98")

        // 提取音频（若有）
        let audioURL = folder.appendingPathComponent("audio.m4a")
        LogStore.log("xdz.subject.audio.start clip=\(clipID)")
        do {
            if try await AudioExtractor().extractAudio(from: url, to: audioURL, timeRange: timeRange) {
                clip.audioURL = audioURL
            }
        } catch is CancellationError {
            throw SegmentationError.cancelled
        } catch {
            // 可选音轨失败不能让已提取的全部 PNG 被失败清理逻辑删除。
            LogStore.log("segmentVideo audio.failed: keeping silent clip=\(clipID) error=\(error)")
            try? FileManager.default.removeItem(at: audioURL)
        }
        LogStore.log("xdz.subject.audio.done clip=\(clipID) hasAudio=\(clip.audioURL != nil)")
        if isCancelled() || Task.isCancelled {
            throw SegmentationError.cancelled
        }

        progress?(ProgressInfo(
            fraction: 1,
            frameIndex: index,
            totalFrames: max(totalFrames, index)
        ))

        LogStore.log("segmentVideo done: clip=\(clipID) name=\(name) frames=\(clip.frameCount) fps=\(clip.fps) size=\(clip.width)x\(clip.height) duration=\(clip.duration)s audio=\(clip.audioURL != nil)")
        try FrameCache.shared.register(clip)
        succeeded = true
        return clip
    }

    /// 单张照片抠图：实例掩码 → 透明 PNG → 生成 1 帧的素材
    public func segmentPhoto(
        from source: CGImage,
        name: String = NSLocalizedString("素材", comment: "Default clip name"),
        algorithm: SegmentationAlgorithm = .visionPerson,
        selectionRegion: [CGPoint]? = nil,
        sam2Prompt: SAM2Prompt? = nil,
        maxDimension: CGFloat = 1280
    ) throws -> SegmentedClip {
        let sourceImage = CIImage(cgImage: source)
        let scale = min(1.0, maxDimension / max(sourceImage.extent.width, sourceImage.extent.height))
        let input = scale < 1.0
            ? sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : sourceImage
        guard let cgImage = context.createCGImage(input, from: input.extent) else {
            throw SegmentationError.noFrames
        }
        let segmented: CGImage
        switch algorithm {
        case .foreground:
            segmented = try VisionPersonSegmenter().segmentedImage(
                from: cgImage,
                source: .foreground,
                selectedInstances: nil
            )
        case .visionPerson:
            segmented = try VisionPersonSegmenter().segmentedImage(from: cgImage)
        case .sam2:
            let prompt = sam2Prompt
                ?? selectionRegion.flatMap { region in
                    SAM2Segmenter.promptPoint(in: region).map {
                        SAM2Prompt(foregroundPoints: [$0])
                    }
                }
            guard let prompt, prompt.isUsable else {
                throw SAM2Error.invalidImage
            }
            let sam2 = try SAM2Segmenter.bundled()
            let inputImage = CIImage(cgImage: cgImage)
            guard let mask = sam2.mask(for: inputImage, prompt: prompt),
                  let sam2Output = context.createCGImage(
                      applyLuminanceMask(inputImage, with: mask),
                      from: inputImage.extent.integral
                  ) else {
                throw PersonSegmenterError.noSubject
            }
            let targetBounds = sam2.normalizedBounds(of: mask)
            if let targetBounds,
               let hybrid = try? VisionPersonSegmenter().segmentedPersonImage(
                   from: cgImage,
                   matching: targetBounds,
                   targetPoint: prompt.primaryForegroundPoint
               ),
               hybrid.score >= 0.20 {
                LogStore.log(
                    "xdz.sam2.photo hybrid=vision-person score=\(String(format: "%.3f", hybrid.score))"
                )
                segmented = hybrid.image
            } else {
                LogStore.log("xdz.sam2.photo hybrid=vision-fallback-sam2")
                segmented = sam2Output
            }
        }

        let clipID = UUID().uuidString
        let folder = try FrameCache.shared.makeClipFolder(id: clipID)
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let frameURL = folder.appendingPathComponent("00000.png")
        guard writePNG(segmented, to: frameURL) else { throw SegmentationError.noFrames }

        let clip = SegmentedClip(
            id: clipID,
            name: name,
            fps: 1,
            frameCount: 1,
            width: segmented.width,
            height: segmented.height,
            folderURL: folder
        )
        LogStore.log("segmentPhoto done: clip=\(clipID) name=\(name) input=\(sourceImage.extent.width)x\(sourceImage.extent.height) output=\(segmented.width)x\(segmented.height)")
        try FrameCache.shared.register(clip)
        succeeded = true
        return clip
    }

    /// 将当前帧的 Vision 实例与上一帧轨迹匹配。Vision 的实例编号不跨帧稳定，
    /// 因此使用包围盒 IoU、中心距离和面积变化做轻量级关联。
    private func debugThumbnail(from image: CGImage) -> CGImage? {
        let maximumDimension: CGFloat = 360
        let sourceDimension = max(CGFloat(image.width), CGFloat(image.height))
        let scale = min(1, maximumDimension / max(sourceDimension, 1))
        guard scale < 1 else { return image }
        let ciImage = CIImage(cgImage: image).transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        return context.createCGImage(ciImage, from: ciImage.extent.integral)
    }

    private struct DebugGridPoint: Hashable {
        let x: Int
        let y: Int
    }

    /// 从 32×32 掩码指纹提取一个阶梯状外轮廓。它用于调试主体关联，
    /// 不参与实际抠图，因此保留低分辨率可以避免分析阶段额外生成图像掩码。
    private func maskContour(from signature: [UInt8]) -> [CGPoint] {
        let dimension = Int(Double(signature.count).squareRoot())
        guard dimension > 1, dimension * dimension == signature.count else { return [] }
        func visible(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < dimension, y >= 0, y < dimension else { return false }
            return signature[y * dimension + x] != 0
        }
        func point(_ x: Int, _ y: Int) -> DebugGridPoint {
            DebugGridPoint(x: x, y: y)
        }

        var edges: [(DebugGridPoint, DebugGridPoint)] = []
        for y in 0..<dimension {
            for x in 0..<dimension where visible(x, y) {
                if !visible(x, y - 1) { edges.append((point(x, y), point(x + 1, y))) }
                if !visible(x + 1, y) { edges.append((point(x + 1, y), point(x + 1, y + 1))) }
                if !visible(x, y + 1) { edges.append((point(x + 1, y + 1), point(x, y + 1))) }
                if !visible(x - 1, y) { edges.append((point(x, y + 1), point(x, y))) }
            }
        }
        guard let first = edges.first else { return [] }
        var contour = [first.0, first.1]
        var current = first.1
        var remaining = Array(edges.dropFirst())
        var guardCount = 0
        while current != first.0, guardCount < edges.count + 2 {
            guardCount += 1
            guard let nextIndex = remaining.firstIndex(where: { $0.0 == current }) else { break }
            let next = remaining.remove(at: nextIndex)
            current = next.1
            contour.append(current)
        }
        guard contour.count >= 3 else { return [] }
        return contour.map {
            CGPoint(
                x: CGFloat($0.x) / CGFloat(dimension),
                y: CGFloat($0.y) / CGFloat(dimension)
            )
        }
    }

    private func assignTracks(
        infos: [ForegroundInstanceInfo],
        frameIndex: Int,
        states: inout [Int: SubjectTrackState],
        nextTrackID: inout Int,
        maxGapFrames: Int,
        allowedTrackIDs: Set<Int>? = nil
    ) -> [Int: Int] {
        var mapping: [Int: Int] = [:]
        var usedTrackIDs = Set<Int>()

        for info in infos.sorted(by: { $0.area > $1.area }) {
            var bestID: Int?
            var bestScore = -Double.infinity

            for (id, state) in states
                where !usedTrackIDs.contains(id)
                    && (allowedTrackIDs == nil || allowedTrackIDs?.contains(id) == true) {
                let gap = frameIndex - state.lastFrame
                guard gap <= maxGapFrames else { continue }
                let overlap = intersectionOverUnion(info.boundingBox, state.lastBoundingBox)
                let distance = pointDistance(info.center, state.lastCenter)
                let areaRatio = min(
                    Double(info.area) / max(state.areaTotal / Double(max(state.frameCount, 1)), 1),
                    Double(state.areaTotal / Double(max(state.frameCount, 1))) / max(Double(info.area), 1)
                )
                let maskSimilarity = maskSignatureIoU(info.maskSignature, state.lastMaskSignature)
                // Vision 的实例框经常是整画布，优先使用掩码中心和面积
                // 连续性。掩码指纹用于两个人靠近时避免实例 1/2 互相交换。
                let score = overlap * 0.15
                    + max(0, 1 - distance) * 0.45
                    + areaRatio * 0.15
                    + maskSimilarity * 0.25
                let signatureIsCompatible = state.lastMaskSignature.isEmpty
                    || maskSimilarity >= 0.08
                    || distance < 0.16
                let acceptable = signatureIsCompatible && (distance < 0.42 || overlap > 0.02)
                if acceptable && score > bestScore {
                    bestScore = score
                    bestID = id
                }
            }

            let trackID: Int
            if let bestID {
                trackID = bestID
                usedTrackIDs.insert(bestID)
                if var state = states[bestID] {
                    // Vision 的实例编号在两个主体靠近时会短暂交换。只有当
                    // 新编号连续稳定出现几帧，才允许它替换当前轨迹；否则
                    // 本帧不建立 mapping，让渲染阶段沿用上一帧掩码。
                    if let lastInstanceIndex = state.lastInstanceIndex,
                       lastInstanceIndex != info.index {
                        if state.pendingInstanceIndex == info.index {
                            state.pendingInstanceCount += 1
                        } else {
                            state.pendingInstanceIndex = info.index
                            state.pendingInstanceCount = 1
                        }
                        let switchConfirmationFrames = 3
                        if state.pendingInstanceCount < switchConfirmationFrames {
                            states[bestID] = state
                            LogStore.log(
                                "xdz.subject.track.switchPending id=\(bestID) "
                                    + "from=\(lastInstanceIndex) to=\(info.index) "
                                    + "count=\(state.pendingInstanceCount)/\(switchConfirmationFrames)"
                            )
                            continue
                        }
                    }
                    state.lastBoundingBox = info.boundingBox
                    state.lastCenter = info.center
                    state.lastMaskSignature = info.maskSignature
                    state.lastFrame = frameIndex
                    state.frameCount += 1
                    state.areaTotal += Double(info.area)
                    state.lastInstanceIndex = info.index
                    state.pendingInstanceIndex = nil
                    state.pendingInstanceCount = 0
                    states[bestID] = state
                }
            } else {
                guard allowedTrackIDs == nil else { continue }
                trackID = nextTrackID
                nextTrackID += 1
                states[trackID] = SubjectTrackState(
                    id: trackID,
                    lastBoundingBox: info.boundingBox,
                    lastCenter: info.center,
                    lastFrame: frameIndex,
                    firstFrame: frameIndex,
                    frameCount: 1,
                    areaTotal: Double(info.area),
                    previewBoundingBox: frameIndex == 0 ? info.boundingBox : nil,
                    lastMaskSignature: info.maskSignature,
                    lastInstanceIndex: info.index,
                    pendingInstanceIndex: nil,
                    pendingInstanceCount: 0
                )
                LogStore.log(
                    "xdz.subject.track.create id=\(trackID) frame=\(frameIndex) "
                        + "bbox=\(info.boundingBox) area=\(info.area)"
                )
                usedTrackIDs.insert(trackID)
            }
            mapping[info.index] = trackID
        }

        return mapping
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let union = lhs.union(rhs).width * lhs.union(rhs).height
        guard union > 0 else { return 0 }
        return Double(intersection.width * intersection.height / union)
    }

    /// Reject a refreshed SAM2 mask when it jumps to a different object or
    /// suddenly expands to most of the frame. The previous accepted mask plus
    /// the lightweight tracker is more stable than accepting that outlier.
    private func isStableSAM2Candidate(_ candidate: CGRect, previous: CGRect?) -> Bool {
        let candidateArea = candidate.width * candidate.height
        guard candidateArea > 0.002, candidateArea < 0.82 else { return false }
        guard let previous else { return true }

        let previousArea = max(previous.width * previous.height, 0.0001)
        let areaRatio = candidateArea / previousArea
        let overlap = intersectionOverUnion(candidate, previous)
        let centerDelta = centerDistance(candidate, previous)
        return areaRatio > 0.25
            && areaRatio < 4.0
            && (overlap >= 0.12 || centerDelta <= 0.18)
    }

    private func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        return min(1, Double(sqrt(dx * dx + dy * dy) / 1.41421356237))
    }

    private func pointDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return min(1, Double(sqrt(dx * dx + dy * dy) / 1.41421356237))
    }

    private func maskSignatureIoU(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        var intersection = 0
        var union = 0
        for index in lhs.indices {
            let lhsVisible = lhs[index] != 0
            let rhsVisible = rhs[index] != 0
            if lhsVisible && rhsVisible { intersection += 1 }
            if lhsVisible || rhsVisible { union += 1 }
        }
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func visionBounds(from topLeftBounds: CGRect) -> CGRect {
        CGRect(
            x: topLeftBounds.minX,
            y: 1 - topLeftBounds.maxY,
            width: topLeftBounds.width,
            height: topLeftBounds.height
        )
    }

    private func seedSAM2Tracker(
        bounds: CGRect,
        objectTracker: inout VNTrackObjectRequest?
    ) {
        let observation = VNDetectedObjectObservation(
            boundingBox: visionBounds(from: bounds)
        )
        let tracker = VNTrackObjectRequest(detectedObjectObservation: observation)
        tracker.trackingLevel = .fast
        objectTracker = tracker
    }

    /// Move a full-frame SAM2 mask from the last refreshed object box to the
    /// current Vision-tracked box. Both rectangles use normalized top-left
    /// coordinates, while the CI image uses pixel coordinates.
    private func transformedMask(
        _ mask: CIImage,
        from sourceBounds: CGRect,
        to targetBounds: CGRect,
        extent: CGRect
    ) -> CIImage {
        guard sourceBounds.width > 0.001, sourceBounds.height > 0.001 else {
            return mask.cropped(to: extent)
        }
        let scaleX = targetBounds.width / sourceBounds.width
        let scaleY = targetBounds.height / sourceBounds.height
        let sourceX = sourceBounds.minX * extent.width
        let sourceY = sourceBounds.minY * extent.height
        let targetX = targetBounds.minX * extent.width
        let targetY = targetBounds.minY * extent.height
        let transform = CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: targetX - sourceX * scaleX,
            ty: targetY - sourceY * scaleY
        )
        return mask
            .transformed(by: transform)
            .cropped(to: extent)
    }

    private func topLeftBounds(from visionBounds: CGRect) -> CGRect {
        CGRect(
            x: visionBounds.minX,
            y: 1 - visionBounds.maxY,
            width: visionBounds.width,
            height: visionBounds.height
        )
    }

    private func normalizedSelectionShape(from points: [CGPoint]?) -> [CGPoint]? {
        guard let points, points.count >= 3 else { return nil }
        let bounds = points.reduce(into: CGRect.null) { result, point in
            result = result.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        return points.map {
            CGPoint(
                x: ($0.x - bounds.minX) / bounds.width,
                y: ($0.y - bounds.minY) / bounds.height
            )
        }
    }

    private func normalizedBounds(of points: [CGPoint]?) -> CGRect? {
        guard let points, points.count >= 3 else { return nil }
        let bounds = points.reduce(into: CGRect.null) { result, point in
            result = result.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        guard !bounds.isNull, bounds.width > 0.001, bounds.height > 0.001 else {
            return nil
        }
        return bounds
    }

    private func trackedBounds(_ bounds: CGRect) -> CGRect? {
        guard bounds.width > 0.02, bounds.height > 0.02,
              bounds.width < 0.95, bounds.height < 0.95,
              bounds.minX >= 0, bounds.minY >= 0,
              bounds.maxX <= 1, bounds.maxY <= 1 else {
            return nil
        }
        return bounds
    }

    private func transformedPolygon(
        _ points: [CGPoint],
        from sourceBounds: CGRect,
        to targetBounds: CGRect
    ) -> [CGPoint] {
        let scaleX = targetBounds.width / max(sourceBounds.width, 0.001)
        let scaleY = targetBounds.height / max(sourceBounds.height, 0.001)
        return points.map { point in
            CGPoint(
                x: targetBounds.minX + (point.x - sourceBounds.minX) * scaleX,
                y: targetBounds.minY + (point.y - sourceBounds.minY) * scaleY
            )
        }
    }

    private func normalizedAbsoluteSelectionShape(from points: [CGPoint]?) -> [CGPoint]? {
        guard let points, points.count >= 3 else { return nil }
        return points.map {
            CGPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1))
        }
    }

    private func boundingBoxIntersectsSelection(
        _ box: CGRect,
        polygon: [CGPoint]
    ) -> Bool {
        // Vision boxes use a bottom-left origin; the lasso uses the canvas
        // top-left origin. Test the box center and corners in canvas space.
        let canvasBox = CGRect(
            x: box.minX,
            y: 1 - box.maxY,
            width: box.width,
            height: box.height
        )
        let samples = [
            CGPoint(x: canvasBox.midX, y: canvasBox.midY),
            CGPoint(x: canvasBox.minX, y: canvasBox.minY),
            CGPoint(x: canvasBox.maxX, y: canvasBox.minY),
            CGPoint(x: canvasBox.maxX, y: canvasBox.maxY),
            CGPoint(x: canvasBox.minX, y: canvasBox.maxY)
        ]
        return samples.contains { pointIsInsidePolygon($0, polygon: polygon) }
            || polygon.contains { canvasBox.contains($0) }
    }

    private func pointIsInsidePolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            let denominator = previous.y - current.y
            if crosses, abs(denominator) > 0.000001 {
                let x = (previous.x - current.x) * (point.y - current.y)
                    / denominator + current.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private func normalizedVisibleBounds(in image: CGImage) -> CGRect? {
        guard image.width > 0, image.height > 0 else { return nil }

        // Vision's generated image can contain a few low-alpha pixels around
        // the canvas. A raw min/max bounds calculation then becomes the whole
        // frame and makes the lasso appear static. Calculate occupancy on a
        // small grid and keep columns/rows that contain a meaningful amount
        // of the selected person's mask.
        let sampleSize = 160
        let bytesPerRow = sampleSize * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * sampleSize)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(
                data: buffer.baseAddress,
                width: sampleSize,
                height: sampleSize,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            bitmap.clear(CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            return true
        }
        guard rendered else { return nil }

        let threshold: UInt8 = 40
        var rowCounts = [Int](repeating: 0, count: sampleSize)
        var columnCounts = [Int](repeating: 0, count: sampleSize)
        for y in 0..<sampleSize {
            let rowStart = y * bytesPerRow
            for x in 0..<sampleSize where pixels[rowStart + x * 4 + 3] > threshold {
                rowCounts[y] += 1
                columnCounts[x] += 1
            }
        }

        let occupancyThreshold = max(2, Int(Double(sampleSize) * 0.018))
        guard let minX = columnCounts.firstIndex(where: { $0 >= occupancyThreshold }),
              let maxX = columnCounts.lastIndex(where: { $0 >= occupancyThreshold }),
              let minY = rowCounts.firstIndex(where: { $0 >= occupancyThreshold }),
              let maxY = rowCounts.lastIndex(where: { $0 >= occupancyThreshold }) else {
            guard let bounds = AlphaSubjectBounds.visiblePixelBounds(in: image) else { return nil }
            return CGRect(
                x: bounds.minX / CGFloat(image.width),
                y: 1 - bounds.maxY / CGFloat(image.height),
                width: bounds.width / CGFloat(image.width),
                height: bounds.height / CGFloat(image.height)
            )
        }

        return CGRect(
            x: CGFloat(minX) / CGFloat(sampleSize),
            y: 1 - CGFloat(maxY + 1) / CGFloat(sampleSize),
            width: CGFloat(maxX - minX + 1) / CGFloat(sampleSize),
            height: CGFloat(maxY - minY + 1) / CGFloat(sampleSize)
        )
    }

    private func polygonMask(
        for points: [CGPoint],
        width: Int,
        height: Int
    ) -> CIImage? {
        guard points.count >= 3, width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.beginPath()
        let first = points[0]
        context.move(to: CGPoint(x: first.x * CGFloat(width), y: (1 - first.y) * CGFloat(height)))
        for point in points.dropFirst() {
            context.addLine(to: CGPoint(
                x: point.x * CGFloat(width),
                y: (1 - point.y) * CGFloat(height)
            ))
        }
        context.closePath()
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    private func applyAlphaMask(_ image: CIImage, with mask: CIImage) -> CIImage {
        let extent = image.extent
        let clear = CIImage(color: CIColor.clear).cropped(to: extent)
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask.cropped(to: extent)
        ])
    }

    /// SAM2 returns a grayscale confidence mask, so use luminance rather than
    /// alpha as the mask channel. Vision's transparent output continues to use
    /// `applyAlphaMask` above.
    private func applyLuminanceMask(_ image: CIImage, with mask: CIImage) -> CIImage {
        let extent = image.extent
        let clear = CIImage(color: CIColor.clear).cropped(to: extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask.cropped(to: extent)
        ])
    }

    private func applyMask(foreground: CIImage, personMask: CIImage) -> CIImage {
        let extent = foreground.extent
        // 直接使用 alpha 通道。CIBlendWithMask 会读取灰度亮度，
        // 把透明 RGB 图像当成普通灰度遮罩容易出现反相/负片效果。
        let mask = personMask.cropped(to: extent)
        let clear = CIImage(color: CIColor.clear).cropped(to: extent)
        return foreground.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask
        ])
    }

}
