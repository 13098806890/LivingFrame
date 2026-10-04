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
    /// Live Photo 的标准交互窗口上限；视频超过此时长时由界面让用户选择区间。
    static let livePhotoMaximumDuration: TimeInterval = 3.0

    enum Target: Equatable {
        case livePhoto
        case video
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

    func convert(
        sourceURL: URL,
        sourceName: String,
        sourceFileExtension: String,
        target: Target,
        sourceRange: ClosedRange<TimeInterval>? = nil,
        progress: @escaping (Double) -> Void,
        warning: @escaping (String) -> Void = { _ in }
    ) async throws {
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
        defer {
            let storedURL = backgroundStore.mediaURL(named: mediaID)
            try? FileManager.default.removeItem(at: storedURL)
            backgroundStore.purgeDecodedMedia()
        }

        progress(0.04)
        let media = await backgroundStore.allUserMedia().first { $0.id == mediaID }
        guard let media, media.width > 0, media.height > 0 else {
            LogStore.log("xdz.convert.fail reason=mediaUnavailable id=\(mediaID)")
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

        let duration: TimeInterval
        switch target {
        case .livePhoto:
            // Live Photo 的标准交互窗口不能超过 3 秒；保持现有导出器约束。
            duration = min(selectedDuration, Self.livePhotoMaximumDuration)
        case .video:
            duration = selectedDuration
        }

        let sourceDuration = max(media.duration, 0.1)

        // 视频（包括 Live Photo 的配对视频）可能带有原始音轨。转换前先准备
        // 与画面区间一致的音频源：整段转换时直接复用原文件，需要截取区间时
        // 生成临时 m4a，避免所选画面与声音错位。GIF 没有 AVAsset 音轨，必须
        // 跳过音频探测，否则某些系统版本会在 GIF 转换前抛出资源读取错误。
        var temporaryAudioURL: URL?
        let audioSourceURL: URL?
        if ["mov", "mp4", "m4v"].contains(extensionName) {
            do {
                audioSourceURL = try await makeAudioSourceURL(
                    sourceURL: sourceURL,
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
                warning(NSLocalizedString(
                    "转换时无法保留源音频，已继续保存无声视频。",
                    comment: "Audio fallback warning during conversion"
                ))
            }
        } else {
            audioSourceURL = nil
            LogStore.log("xdz.convert.audio.skip reason=nonVideoInput")
        }
        defer {
            if let temporaryAudioURL {
                try? FileManager.default.removeItem(at: temporaryAudioURL)
            }
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

        switch target {
        case .livePhoto:
            LogStore.log("xdz.convert.export.begin target=livePhoto duration=\(duration) range=\(sourceStartTime)-\(sourceEndTime)")
            try await exportLivePhoto(
                conversionComposition,
                sourceName: sourceName,
                audioSourceURL: audioSourceURL,
                progress: progress
            )
        case .video:
            LogStore.log("xdz.convert.export.begin target=video duration=\(duration) range=\(sourceStartTime)-\(sourceEndTime)")
            try await exportVideo(
                conversionComposition,
                sourceName: sourceName,
                audioSourceURL: audioSourceURL,
                progress: progress
            )
        }
    }

    private func exportVideo(
        _ composition: Composition,
        sourceName: String,
        audioSourceURL: URL?,
        progress: @escaping (Double) -> Void
    ) async throws {
        let url = temporaryURL(
            sourceName: sourceName,
            suffix: "video",
            fileExtension: "mov"
        )
        defer { try? FileManager.default.removeItem(at: url) }

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
        do {
            LogStore.log("xdz.convert.photoSave.begin type=video")
            try await saveVideoToPhotoLibrary(url, sourceName: sourceName)
            LogStore.log("xdz.convert.photoSave.done type=video")
        } catch {
            LogStore.log("xdz.convert.photoSave.fail type=video error=\(error)")
            throw error
        }
        progress(1)
    }

    private func exportLivePhoto(
        _ composition: Composition,
        sourceName: String,
        audioSourceURL: URL?,
        progress: @escaping (Double) -> Void
    ) async throws {
        let url = temporaryURL(
            sourceName: sourceName,
            suffix: "live-photo",
            fileExtension: "mov"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let output = try await LivePhotoExporter().export(
            composition,
            to: url,
            audioURL: audioSourceURL,
            watermark: nil,
            progress: progress,
            isCancelled: { Task.isCancelled }
        )
        try await saveLivePhotoToPhotoLibrary(output, sourceName: sourceName)
        progress(1)
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
            .appendingPathComponent("GIFBloom-conversion-audio-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let start = CMTime(seconds: sourceStartTime, preferredTimescale: 600)
        let duration = CMTime(seconds: max(sourceEndTime - sourceStartTime, 0.1), preferredTimescale: 600)
        let extracted = try await AudioExtractor().extractAudio(
            from: sourceURL,
            to: outputURL,
            timeRange: CMTimeRange(start: start, duration: duration)
        )
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
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
            options.originalFilename = "\(safeFileName(sourceName))-video.mov"
            request.addResource(with: .video, fileURL: url, options: options)
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
        try FileManager.default.copyItem(at: output.videoURL, to: videoURL)
        try output.coverData.write(to: coverURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: coverURL)
        }

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
                "\(safeFileName(sourceName))-\(suffix)-\(UUID().uuidString)"
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
