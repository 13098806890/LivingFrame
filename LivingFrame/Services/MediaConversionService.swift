import AVFoundation
import CoreGraphics
import Foundation
import LivingFrameCore
import Photos
import UniformTypeIdentifiers

/// 将相册中的 GIF/视频转换为 Live Photo，或将 Live Photo 的配对视频导出为普通视频。
///
/// 转换使用与编辑器导出相同的 CompositionRenderer 和 Core 导出器，因此 GIF、视频
/// 和 Live Photo 的方向、帧读取以及编码行为不会在素材库入口形成第二套实现。
struct MediaConversionService {
    /// The conversion UI offers these upper bounds for video-to-Live-Photo clips.
    static let livePhotoMaximumDurations: [TimeInterval] = [5, 15]
    static let defaultLivePhotoMaximumDuration: TimeInterval = 5
    private static let gifLivePhotoMaximumDuration: TimeInterval = 3

    enum Target: Equatable {
        case livePhoto
        case video
    }

    /// Holds generated files until the user saves or dismisses the preview.
    /// A class keeps file ownership stable while SwiftUI copies view state.
    final class PreparedConversion: Identifiable {
        let id = UUID()
        let target: Target
        let sourceName: String
        let duration: TimeInterval
        let livePhotoMaximumDuration: TimeInterval
        let sourceSize: CGSize
        private(set) var hasOutputAudio: Bool
        private(set) var audioWarningMessage: String?
        let sourceMediaID: String
        let sourceFileExtension: String
        let audioURL: URL?
        let baseComposition: Composition
        private(set) var previewURL: URL
        /// The first rendered preview remains available while the batch is open,
        /// so a later page can crop or save the same item again after switching.
        let initialPreviewURL: URL
        private(set) var livePhotoOutput: LivePhotoExporter.Output?
        private(set) var renderedCrop: CGRect?
        fileprivate(set) var isDiscarded = false

        init(
            target: Target,
            sourceName: String,
            duration: TimeInterval,
            livePhotoMaximumDuration: TimeInterval,
            sourceSize: CGSize,
            hasOutputAudio: Bool,
            audioWarningMessage: String?,
            sourceMediaID: String,
            sourceFileExtension: String,
            audioURL: URL?,
            baseComposition: Composition,
            previewURL: URL,
            livePhotoOutput: LivePhotoExporter.Output?
        ) {
            self.target = target
            self.sourceName = sourceName
            self.duration = duration
            self.livePhotoMaximumDuration = livePhotoMaximumDuration
            self.sourceSize = sourceSize
            self.hasOutputAudio = hasOutputAudio
            self.audioWarningMessage = audioWarningMessage
            self.sourceMediaID = sourceMediaID
            self.sourceFileExtension = sourceFileExtension
            self.audioURL = audioURL
            self.baseComposition = baseComposition
            self.previewURL = previewURL
            self.initialPreviewURL = previewURL
            self.livePhotoOutput = livePhotoOutput
        }

        func updateRenderedOutput(
            url: URL,
            livePhotoOutput: LivePhotoExporter.Output?,
            crop: CGRect?
        ) {
            let oldURL = previewURL
            previewURL = url
            self.livePhotoOutput = livePhotoOutput
            renderedCrop = crop
            if oldURL != url, oldURL != initialPreviewURL {
                try? FileManager.default.removeItem(at: oldURL)
            }
        }

        func updateAudioStatus(hasOutputAudio: Bool, warningMessage: String?) {
            self.hasOutputAudio = hasOutputAudio
            audioWarningMessage = warningMessage
        }

        func markDiscarded() { isDiscarded = true }
    }

    enum ConversionError: LocalizedError {
        case unsupportedInput
        case mediaUnavailable
        case photoLibraryDenied

        var errorDescription: String? {
            switch self {
            case .unsupportedInput:
                return NSLocalizedString(
                    "这个素材格式不支持当前转换。请选择 GIF、视频或 Live Photo。",
                    comment: "Unsupported conversion input"
                )
            case .mediaUnavailable:
                return NSLocalizedString(
                    "转换素材暂时无法读取，请重新选择后重试。",
                    comment: "Conversion media unavailable"
                )
            case .photoLibraryDenied:
                return NSLocalizedString(
                    "没有获得保存到照片的权限，请在系统设置中允许后重试。",
                    comment: "Conversion photo library denied"
                )
            }
        }
    }

    /// Compatibility wrapper for the original immediate-save behavior.
    func convert(
        sourceURL: URL,
        sourceName: String,
        sourceFileExtension: String,
        target: Target,
        sourceRange: ClosedRange<TimeInterval>? = nil,
        livePhotoMaximumDuration: TimeInterval = Self.defaultLivePhotoMaximumDuration,
        progress: @escaping (Double) -> Void,
        warning: @escaping (String) -> Void = { _ in }
    ) async throws {
        let prepared = try await prepare(
            sourceURL: sourceURL,
            sourceName: sourceName,
            sourceFileExtension: sourceFileExtension,
            target: target,
            sourceRange: sourceRange,
            livePhotoMaximumDuration: livePhotoMaximumDuration,
            progress: progress,
            warning: warning
        )
        defer { discard(prepared) }
        try await save(prepared, cropRect: nil)
    }

    func prepare(
        sourceURL: URL,
        sourceName: String,
        sourceFileExtension: String,
        target: Target,
        sourceRange: ClosedRange<TimeInterval>? = nil,
        livePhotoMaximumDuration: TimeInterval = Self.defaultLivePhotoMaximumDuration,
        progress: @escaping (Double) -> Void,
        warning: @escaping (String) -> Void = { _ in }
    ) async throws -> PreparedConversion {
        try Task.checkCancellation()
        LogStore.log("xdz.convert.begin target=\(target) name=\(sourceName) ext=\(sourceFileExtension) url=\(sourceURL.path)")
        let extensionName = sourceFileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let backgroundStore = BackgroundStore.shared
        let mediaID: String?

        if extensionName == "gif" {
            let sourceData: Data
            do {
                sourceData = try Data(contentsOf: sourceURL)
                LogStore.log("xdz.convert.sourceData.ready bytes=\(sourceData.count)")
            } catch {
                LogStore.log("xdz.convert.sourceData.fail error=\(error)")
                throw error
            }
            mediaID = backgroundStore.saveUserImage(
                sourceData,
                preferredFileExtension: "gif"
            )
        } else if ["mov", "mp4", "m4v"].contains(extensionName) {
            // 视频源已经是本地文件，直接复制到 BackgroundStore，避免把整个
            // 大视频读成 Data 后再写回磁盘，降低内存峰值和 iCloud 转换失败率。
            mediaID = copyVideoToBackgroundStore(
                sourceURL,
                store: backgroundStore,
                preferredFileExtension: extensionName
            )
            LogStore.log("xdz.convert.sourceFile.copied id=\(mediaID ?? "nil") bytes=\((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? 0)")
        } else {
            LogStore.log("xdz.convert.fail reason=unsupportedExtension ext=\(extensionName)")
            throw ConversionError.unsupportedInput
        }

        guard let mediaID else {
            LogStore.log("xdz.convert.fail reason=saveUserMediaReturnedNil ext=\(extensionName)")
            throw ConversionError.mediaUnavailable
        }
        LogStore.log("xdz.convert.background.saved id=\(mediaID) ext=\(extensionName)")
        var temporaryAudioURL: URL?
        var generatedPreviewURL: URL?
        var retainedForPreview = false
        defer {
            if !retainedForPreview {
                if let generatedPreviewURL { try? FileManager.default.removeItem(at: generatedPreviewURL) }
                if let temporaryAudioURL { try? FileManager.default.removeItem(at: temporaryAudioURL) }
                try? FileManager.default.removeItem(at: backgroundStore.mediaURL(named: mediaID))
                backgroundStore.purgeDecodedMedia()
            }
        }
        progress(0.04)
        let metadataLookupStart = Date()
        let copiedURL = backgroundStore.mediaURL(named: mediaID)
        let copiedFileSize = (try? FileManager.default.attributesOfItem(atPath: copiedURL.path)[.size] as? Int) ?? 0
        LogStore.log("xdz.convert.media.lookup.begin id=\(mediaID) bytes=\(copiedFileSize) path=\(copiedURL.path)")
        let media = await backgroundStore.userMedia(named: mediaID)
        LogStore.log("xdz.convert.media.lookup.done id=\(mediaID) found=\(media != nil) elapsed=\(Date().timeIntervalSince(metadataLookupStart))")
        guard let media, media.width > 0, media.height > 0 else {
            LogStore.log("xdz.convert.fail reason=mediaUnavailable id=\(mediaID) size=\(media?.width ?? 0)x\(media?.height ?? 0)")
            throw ConversionError.mediaUnavailable
        }
        LogStore.log("xdz.convert.media.ready id=\(mediaID) size=\(media.width)x\(media.height) duration=\(media.duration)")

        let requestedStart = sourceRange?.lowerBound ?? 0
        let requestedEnd = sourceRange?.upperBound ?? media.duration
        let sourceStartTime = min(max(requestedStart, 0), max(media.duration, 0))
        let sourceEndTime = min(
            max(requestedEnd, sourceStartTime),
            max(media.duration, sourceStartTime)
        )
        let selectedDuration = max(sourceEndTime - sourceStartTime, 0.1)
        let requestedLivePhotoMaximumDuration = Self.livePhotoMaximumDurations.contains(livePhotoMaximumDuration)
            ? livePhotoMaximumDuration
            : Self.defaultLivePhotoMaximumDuration
        // Preserve the existing GIF-to-Live-Photo limit; the new 5/15 second choice
        // applies to video sources only.
        let allowedLivePhotoMaximumDuration = extensionName == "gif"
            ? Self.gifLivePhotoMaximumDuration
            : requestedLivePhotoMaximumDuration

        let duration: TimeInterval
        switch target {
        case .livePhoto:
            duration = min(selectedDuration, allowedLivePhotoMaximumDuration)
        case .video:
            duration = selectedDuration
        }

        let sourceDuration = max(media.duration, 0.1)

        // 视频（包括 Live Photo 的配对视频）可能带有原始音轨。转换前先准备
        // 与画面区间一致的音频源：整段转换时直接复用原文件，需要截取区间时
        // 生成临时 m4a，避免所选画面与声音错位。GIF 没有 AVAsset 音轨，必须
        // 跳过音频探测，否则某些系统版本会在 GIF 转换前抛出资源读取错误。
        let audioSourceURL: URL?
        var audioWarningMessage: String?
        if ["mov", "mp4", "m4v"].contains(extensionName) {
            do {
                audioSourceURL = try await makeAudioSourceURL(
                    sourceURL: backgroundStore.mediaURL(named: mediaID),
                    sourceStartTime: sourceStartTime,
                    sourceEndTime: sourceEndTime,
                    sourceDuration: sourceDuration
                ) { temporaryURL in
                    temporaryAudioURL = temporaryURL
                }
                LogStore.log("xdz.convert.audio.ready present=\(audioSourceURL != nil) url=\(audioSourceURL?.path ?? "nil")")
            } catch {
                LogStore.log("xdz.convert.audio.fail error=\(error)")
                // 音频是增强能力，画面转换不能因音轨损坏、缺失或暂时不可读而失败。
                audioSourceURL = nil
                let message = NSLocalizedString(
                    "转换时无法保留源音频，预览不会包含声音。",
                    comment: "Audio fallback warning during conversion"
                )
                audioWarningMessage = message
                warning(message)
            }
        } else {
            audioSourceURL = nil
            LogStore.log("xdz.convert.audio.skip reason=nonVideoInput")
        }
        let audioClips = audioSourceURL.map {
            [AudioClip(sourceID: $0.path, duration: duration, volume: 1)]
        } ?? []

        let conversionComposition = Composition(
            name: sourceName,
            canvas: CanvasSpec(
                width: CGFloat(max(media.width, 2)),
                height: CGFloat(max(media.height, 2))
            ),
            duration: duration,
            fps: 30,
            elements: [
                CompositionElement(
                    kind: .background(backgroundID: mediaID),
                    name: sourceName,
                    transform: ElementTransform(
                        position: CGPoint(
                            x: CGFloat(media.width) / 2,
                            y: CGFloat(media.height) / 2
                        )
                    ),
                    startTime: 0,
                    endTime: duration,
                    sourceStartTime: sourceStartTime,
                    sourceEndTime: min(sourceEndTime, sourceDuration),
                    backgroundSettings: BackgroundElementSettings(),
                    followsLongestMaterialDuration: true
                )
            ],
            audioClips: audioClips,
            background: .clear
        )

        let previewURL = temporaryURL(
            sourceName: sourceName,
            suffix: target == .livePhoto ? "live-photo-preview" : "video-preview",
            fileExtension: "mov"
        )
        generatedPreviewURL = previewURL
        let livePhotoOutput: LivePhotoExporter.Output?
        switch target {
        case .livePhoto:
            LogStore.log("xdz.convert.export.begin target=livePhoto duration=\(duration) range=\(sourceStartTime)-\(sourceEndTime)")
            livePhotoOutput = try await exportLivePhoto(
                conversionComposition,
                sourceName: sourceName,
                audioSourceURL: audioSourceURL,
                outputURL: previewURL,
                maximumDuration: allowedLivePhotoMaximumDuration,
                progress: { fraction in
                    // 4% marks import and audio preparation; keep export progress
                    // within the remaining range so the progress indicator never moves backwards.
                    progress(0.04 + 0.96 * fraction)
                }
            )
        case .video:
            LogStore.log("xdz.convert.export.begin target=video duration=\(duration) range=\(sourceStartTime)-\(sourceEndTime)")
            try await exportVideo(
                conversionComposition,
                sourceName: sourceName,
                audioSourceURL: audioSourceURL,
                outputURL: previewURL,
                progress: progress
            )
            livePhotoOutput = nil
        }
        progress(1)
        let outputAudioTracks = try? await AVURLAsset(url: previewURL).loadTracks(withMediaType: .audio)
        let hasOutputAudio = !(outputAudioTracks?.isEmpty ?? true)
        if !audioClips.isEmpty, !hasOutputAudio, audioWarningMessage == nil {
            let message = NSLocalizedString(
                "转换时无法保留源音频，预览不会包含声音。",
                comment: "Audio fallback warning during conversion"
            )
            audioWarningMessage = message
            warning(message)
        }
        let prepared = PreparedConversion(
            target: target,
            sourceName: sourceName,
            duration: duration,
            livePhotoMaximumDuration: allowedLivePhotoMaximumDuration,
            sourceSize: CGSize(width: media.width, height: media.height),
            hasOutputAudio: hasOutputAudio,
            audioWarningMessage: audioWarningMessage,
            sourceMediaID: mediaID,
            sourceFileExtension: extensionName,
            audioURL: audioSourceURL,
            baseComposition: conversionComposition,
            previewURL: previewURL,
            livePhotoOutput: livePhotoOutput
        )
        retainedForPreview = true
        return prepared
    }

    func save(_ prepared: PreparedConversion, cropRect: CGRect?) async throws {
        guard !prepared.isDiscarded else { throw ConversionError.mediaUnavailable }
        try await renderCrop(prepared, cropRect: cropRect)

        switch prepared.target {
        case .video:
            try await saveVideoToPhotoLibrary(prepared.previewURL, sourceName: prepared.sourceName)
        case .livePhoto:
            guard let output = prepared.livePhotoOutput else { throw ConversionError.mediaUnavailable }
            try await saveLivePhotoToPhotoLibrary(output, sourceName: prepared.sourceName)
        }
    }

    /// Renders the selected crop into the retained preview without writing to Photos.
    /// The caller can replace its player item with `prepared.previewURL` afterwards.
    func renderCrop(_ prepared: PreparedConversion, cropRect: CGRect?) async throws {
        guard !prepared.isDiscarded else { throw ConversionError.mediaUnavailable }
        let normalized = normalizedCrop(cropRect, canvas: prepared.baseComposition.canvasRect)
        guard prepared.renderedCrop != normalized else { return }
        var composition = prepared.baseComposition
        composition.cropRect = normalized
        let outputURL = temporaryURL(
            sourceName: prepared.sourceName,
            suffix: prepared.target == .livePhoto ? "live-photo-cropped" : "video-cropped",
            fileExtension: "mov"
        )
        var outputTransferred = false
        defer {
            if !outputTransferred { try? FileManager.default.removeItem(at: outputURL) }
        }

        switch prepared.target {
        case .video:
            try await exportVideo(
                composition,
                sourceName: prepared.sourceName,
                audioSourceURL: prepared.audioURL,
                outputURL: outputURL,
                progress: { _ in }
            )
            try Task.checkCancellation()
            guard !prepared.isDiscarded else { throw ConversionError.mediaUnavailable }
            let audioStatus = await audioStatus(for: prepared, outputURL: outputURL)
            try Task.checkCancellation()
            guard !prepared.isDiscarded else { throw ConversionError.mediaUnavailable }
            if let audioStatus {
                prepared.updateAudioStatus(
                    hasOutputAudio: audioStatus.hasOutputAudio,
                    warningMessage: audioStatus.warningMessage
                )
            }
            prepared.updateRenderedOutput(
                url: outputURL,
                livePhotoOutput: nil,
                crop: normalized
            )
        case .livePhoto:
            let output = try await exportLivePhoto(
                composition,
                sourceName: prepared.sourceName,
                audioSourceURL: prepared.audioURL,
                outputURL: outputURL,
                maximumDuration: prepared.livePhotoMaximumDuration,
                progress: { _ in }
            )
            try Task.checkCancellation()
            guard !prepared.isDiscarded else { throw ConversionError.mediaUnavailable }
            let audioStatus = await audioStatus(for: prepared, outputURL: output.videoURL)
            try Task.checkCancellation()
            guard !prepared.isDiscarded else { throw ConversionError.mediaUnavailable }
            if let audioStatus {
                prepared.updateAudioStatus(
                    hasOutputAudio: audioStatus.hasOutputAudio,
                    warningMessage: audioStatus.warningMessage
                )
            }
            prepared.updateRenderedOutput(
                url: output.videoURL,
                livePhotoOutput: output,
                crop: normalized
            )
        }
        outputTransferred = true
    }

    private func audioStatus(
        for prepared: PreparedConversion,
        outputURL: URL
    ) async -> (hasOutputAudio: Bool, warningMessage: String?)? {
        guard !prepared.baseComposition.audioClips.isEmpty else { return nil }
        let tracks = try? await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)
        guard let tracks else { return nil }

        let hasAudio = !tracks.isEmpty
        let warning = hasAudio ? nil : NSLocalizedString(
            "转换时无法保留源音频，预览不会包含声音。",
            comment: "Audio fallback warning during conversion"
        )
        return (hasAudio, warning)
    }

    func discard(_ prepared: PreparedConversion) {
        guard !prepared.isDiscarded else { return }
        prepared.markDiscarded()
        try? FileManager.default.removeItem(at: prepared.previewURL)
        if prepared.initialPreviewURL != prepared.previewURL {
            try? FileManager.default.removeItem(at: prepared.initialPreviewURL)
        }
        if let audioURL = prepared.audioURL,
           audioURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
           audioURL.lastPathComponent.hasPrefix("LF-conversion-audio-") {
            try? FileManager.default.removeItem(at: audioURL)
        }
        let storedURL = BackgroundStore.shared.mediaURL(named: prepared.sourceMediaID)
        try? FileManager.default.removeItem(at: storedURL)
        BackgroundStore.shared.purgeDecodedMedia()
    }

    private func normalizedCrop(_ crop: CGRect?, canvas: CGRect) -> CGRect? {
        guard let crop, crop.width.isFinite, crop.height.isFinite,
              crop.width > 1, crop.height > 1 else { return nil }
        let minX = min(max(crop.minX, canvas.minX), canvas.maxX - 2)
        let minY = min(max(crop.minY, canvas.minY), canvas.maxY - 2)
        let maxX = min(max(crop.maxX, minX + 2), canvas.maxX)
        let maxY = min(max(crop.maxY, minY + 2), canvas.maxY)
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return rect == canvas ? nil : rect
    }

    private func exportVideo(
        _ composition: Composition,
        sourceName: String,
        audioSourceURL: URL?,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let url = outputURL

        LogStore.log("xdz.convert.videoExporter.begin url=\(url.path)")
        do {
            try await VideoExporter().export(
                composition,
                format: .h264,
                sourceResolver: { sourceID in
                    guard let audioSourceURL, sourceID == audioSourceURL.path else { return nil }
                    return audioSourceURL
                },
                to: url,
                fps: composition.fps,
                maxPixelSize: nil,
                watermark: nil,
                progress: progress,
                isCancelled: { Task.isCancelled }
            )
            LogStore.log("xdz.convert.videoExporter.done bytes=\((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)")
        } catch {
            LogStore.log("xdz.convert.videoExporter.fail error=\(error)")
            throw error
        }
    }

    private func exportLivePhoto(
        _ composition: Composition,
        sourceName: String,
        audioSourceURL: URL?,
        outputURL: URL,
        maximumDuration: TimeInterval,
        progress: @escaping (Double) -> Void
    ) async throws -> LivePhotoExporter.Output {
        let output = try await LivePhotoExporter().export(
            composition,
            to: outputURL,
            audioURL: audioSourceURL,
            maximumDuration: maximumDuration,
            watermark: nil,
            progress: progress,
            isCancelled: { Task.isCancelled }
        )
        return output
    }

    /// 返回可直接用于导出的音频源。没有音轨时返回 nil；需要区间裁剪时生成
    /// 临时 m4a，并通过回调交给调用方在转换完成后清理。
    private func makeAudioSourceURL(
        sourceURL: URL,
        sourceStartTime: TimeInterval,
        sourceEndTime: TimeInterval,
        sourceDuration: TimeInterval,
        onTemporaryURL: (URL) -> Void
    ) async throws -> URL? {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return nil }

        let needsTrim = sourceStartTime > 0.001
            || sourceEndTime < sourceDuration - 0.001
        guard needsTrim else { return sourceURL }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-conversion-audio-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let start = CMTime(seconds: sourceStartTime, preferredTimescale: 600)
        let duration = CMTime(seconds: max(sourceEndTime - sourceStartTime, 0.1), preferredTimescale: 600)
        let extracted: Bool
        do {
            extracted = try await AudioExtractor().extractAudio(
                from: sourceURL,
                to: outputURL,
                timeRange: CMTimeRange(start: start, duration: duration)
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        guard extracted, FileManager.default.fileExists(atPath: outputURL.path) else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        onTemporaryURL(outputURL)
        return outputURL
    }

    private func copyVideoToBackgroundStore(
        _ sourceURL: URL,
        store: BackgroundStore,
        preferredFileExtension: String
    ) -> String? {
        let id = "user-\(UUID().uuidString)"
        let allowedExtensions = ["mov", "mp4", "m4v"]
        let fileExtension = allowedExtensions.contains(preferredFileExtension.lowercased())
            ? preferredFileExtension.lowercased()
            : "mov"
        let destination = store.rootURL
            .appendingPathComponent(id)
            .appendingPathExtension(fileExtension)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return id
        } catch {
            LogStore.log("xdz.convert.sourceFile.copyFail error=\(error)")
            return nil
        }
    }

    private func saveVideoToPhotoLibrary(_ url: URL, sourceName: String) async throws {
        let authorized = await requestAddOnlyAuthorization()
        LogStore.log("xdz.convert.photoSave.authorization authorized=\(authorized)")
        guard authorized else {
            throw ConversionError.photoLibraryDenied
        }
        let submissionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-conversion-save-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: submissionURL) }
        try FileManager.default.copyItem(at: url, to: submissionURL)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
            options.originalFilename = "\(safeFileName(sourceName))-video.mov"
            request.addResource(with: .video, fileURL: submissionURL, options: options)
        }
    }

    private func saveLivePhotoToPhotoLibrary(
        _ output: LivePhotoExporter.Output,
        sourceName: String
    ) async throws {
        guard await requestAddOnlyAuthorization() else {
            throw ConversionError.photoLibraryDenied
        }

        let identifier = output.assetIdentifier
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFBloom-LivePhoto-\(identifier).mov")
        let coverURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFBloom-LivePhoto-\(identifier).jpg")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: coverURL)
        }
        try FileManager.default.copyItem(at: output.videoURL, to: videoURL)
        try output.coverData.write(to: coverURL, options: .atomic)

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.shouldMoveFile = true
            photoOptions.uniformTypeIdentifier = UTType.jpeg.identifier
            photoOptions.originalFilename = "\(safeFileName(sourceName))-live-photo.jpg"
            request.addResource(with: .photo, fileURL: coverURL, options: photoOptions)

            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.shouldMoveFile = true
            videoOptions.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
            videoOptions.originalFilename = "\(safeFileName(sourceName))-live-photo.mov"
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
        }
    }

    private func requestAddOnlyAuthorization() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        LogStore.log("xdz.convert.photoSave.authorization.status status=\(status.rawValue)")
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let requested = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return requested == .authorized
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func temporaryURL(
        sourceName: String,
        suffix: String,
        fileExtension: String
    ) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LF-\(safeFileName(sourceName))-\(suffix)-\(UUID().uuidString)"
            )
            .appendingPathExtension(fileExtension)
    }

    private func safeFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let result = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "GIFBloom" : result
    }
}
