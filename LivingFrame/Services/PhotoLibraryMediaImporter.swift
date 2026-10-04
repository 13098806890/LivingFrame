import AVFoundation
import CoreTransferable
import Foundation
import ImageIO
import LivingFrameCore
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 相册媒体读取服务。
///
/// LibraryView 和 AssetPickerView 使用同一套 Live Photo、视频、iCloud 下载和
/// 权限处理，视图层只负责进度展示以及把结果交给对应的业务流程。
enum PhotoLibraryMediaImporter {
    struct ExtractionVideo {
        let url: URL
        let name: String
        let stillOrientation: CGImagePropertyOrientation
        let stillURL: URL?
    }

    struct BackgroundMedia {
        let data: Data
        let fileExtension: String?
        let isVideo: Bool
    }

    static func requestReadWriteAuthorization() async -> PHAuthorizationStatus? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else { return status }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func loadExtractionVideo(
        from item: PhotosPickerItem,
        progress: @escaping @Sendable (Double) -> Void,
        includingStillImage: Bool = true
    ) async -> ExtractionVideo? {
        LogStore.log("xdz.import extraction begin item=\(item.itemIdentifier ?? "nil")")
        if let result = await loadLivePhotoVideo(
            from: item,
            progress: progress,
            includingStillImage: includingStillImage
        ) {
            LogStore.log("xdz.import extraction video ready name=\(result.name)")
            return result
        }
        LogStore.log("xdz.import extraction video unavailable")
        return nil
    }

    static func loadBackgroundMedia(
        from item: PhotosPickerItem,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> BackgroundMedia? {
        LogStore.log("xdz.import background begin item=\(item.itemIdentifier ?? "nil")")
        if let liveVideo = await loadLivePhotoVideoData(from: item, progress: progress) {
            LogStore.log("xdz.import background live/video ready bytes=\(liveVideo.data.count)")
            return liveVideo
        }

        let type = item.supportedContentTypes.first
        if type?.conforms(to: .movie) == true,
           let video = await loadVideoData(from: item, progress: progress) {
            return video
        }

        progress(0.15)
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            LogStore.log("xdz.import background data unavailable")
            return nil
        }
        progress(1)
        return BackgroundMedia(
            data: data,
            fileExtension: type?.preferredFilenameExtension,
            isVideo: false
        )
    }

    private static func loadLivePhotoVideo(
        from item: PhotosPickerItem,
        progress: @escaping @Sendable (Double) -> Void,
        includingStillImage: Bool
    ) async -> ExtractionVideo? {
        LogStore.log("xdz.import.livePhoto.begin item=\(item.itemIdentifier ?? "nil") types=\(item.supportedContentTypes.map(\.identifier))")
        if let identifier = item.itemIdentifier,
           let status = await requestReadWriteAuthorization(),
           (status == .authorized || status == .limited),
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
            asset.mediaSubtypes.contains(.photoLive) {
            let resources = PHAssetResource.assetResources(for: asset)
            let stillOrientation = includingStillImage
                ? await stillOrientation(for: asset, progress: progress)
                : .up
            let stillURL = includingStillImage
                ? await stillImageURL(for: asset, progress: progress)
                : nil

            // 优先让 Photos 返回已解码的视频 URL；如果 iCloud 返回的是
            // AVComposition 或暂时没有可用 URL，则直接请求 pairedVideo 资源。
            if let url = await requestVideoURL(for: asset, progress: progress),
               let copy = await copyToTemporaryFile(url) {
                let name = resources.first?.originalFilename ?? copy.lastPathComponent
                LogStore.log("xdz.import.livePhoto.assetPath success id=\(identifier) url=\(url.path)")
                LogStore.log("xdz.import.livePhoto.assetPath ready temp=\(copy.path) bytes=\((try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int) ?? 0) still=\(stillURL != nil)")
                return ExtractionVideo(
                    url: copy,
                    name: name,
                    stillOrientation: stillOrientation,
                    stillURL: stillURL
                )
            }

            if let videoResource = resources.first(where: { $0.type == .pairedVideo }),
               let destination = await writeResource(videoResource, progress: progress) {
                LogStore.log("xdz.import.livePhoto.assetPath pairedVideoReady id=\(identifier) temp=\(destination.path)")
                return ExtractionVideo(
                    url: destination,
                    name: videoResource.originalFilename,
                    stillOrientation: stillOrientation,
                    stillURL: stillURL
                )
            }
            LogStore.log("xdz.import.livePhoto.assetPath failed id=\(identifier) reason=pairedVideoDownload")
        } else {
            LogStore.log("xdz.import.livePhoto.assetPath unavailable item=\(item.itemIdentifier ?? "nil")")
        }

        let livePhoto: PHLivePhoto?
        do {
            livePhoto = try await item.loadTransferable(type: PHLivePhoto.self)
        } catch {
            LogStore.log("xdz.import.livePhoto.transferable fail error=\(error)")
            livePhoto = nil
        }
        guard let livePhoto,
              let resources = pairedResources(for: livePhoto),
              let videoResource = resources.video,
              let destination = await writeResource(videoResource, progress: progress) else {
            LogStore.log("xdz.import.livePhoto.transferable fail reason=missingPairedVideoOrDownload")
            return nil
        }
        LogStore.log("xdz.import.livePhoto.transferable videoReady temp=\(destination.path) bytes=\((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0)")

        var stillOrientation = CGImagePropertyOrientation.up
        var stillURL: URL?
        if includingStillImage,
           let photoResource = resources.photo,
           let photoDestination = await writeResource(photoResource, progress: progress, fileExtension: "jpg") {
            stillURL = photoDestination
            stillOrientation = exifOrientation(of: photoDestination) ?? .up
        }
        return ExtractionVideo(
            url: destination,
            name: videoResource.originalFilename,
            stillOrientation: stillOrientation,
            stillURL: stillURL
        )
    }

    private static func loadLivePhotoVideoData(
        from item: PhotosPickerItem,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> BackgroundMedia? {
        if let identifier = item.itemIdentifier,
           let status = await requestReadWriteAuthorization(),
           (status == .authorized || status == .limited),
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
           asset.mediaSubtypes.contains(.photoLive),
           let url = await requestVideoURL(for: asset, progress: progress),
           let data = await readData(at: url) {
            progress(1)
            return BackgroundMedia(data: data, fileExtension: url.pathExtension, isVideo: true)
        }

        let livePhoto: PHLivePhoto?
        do {
            livePhoto = try await item.loadTransferable(type: PHLivePhoto.self)
        } catch {
            livePhoto = nil
        }
        guard let livePhoto,
              let videoResource = pairedResources(for: livePhoto)?.video,
              let data = await resourceData(videoResource, progress: progress) else {
            return nil
        }
        return BackgroundMedia(
            data: data,
            fileExtension: URL(fileURLWithPath: videoResource.originalFilename).pathExtension,
            isVideo: true
        )
    }

    private static func loadVideoData(
        from item: PhotosPickerItem,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> BackgroundMedia? {
        if let identifier = item.itemIdentifier,
           let status = await requestReadWriteAuthorization(),
           (status == .authorized || status == .limited),
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
           asset.mediaType == .video,
           let url = await requestVideoURL(for: asset, progress: progress),
           let data = await readData(at: url) {
            progress(1)
            return BackgroundMedia(data: data, fileExtension: url.pathExtension, isVideo: true)
        }

        guard let movie = try? await item.loadTransferable(type: MovieFile.self) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        guard let data = await readData(at: movie.url) else { return nil }
        progress(1)
        return BackgroundMedia(data: data, fileExtension: movie.url.pathExtension, isVideo: true)
    }

    private static func requestVideoURL(
        for asset: PHAsset,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> URL? {
        LogStore.log("xdz.import.livePhoto.requestAVAsset begin id=\(asset.localIdentifier) duration=\(asset.duration)")
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in progress(value) }
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                LogStore.log("xdz.import.livePhoto.requestAVAsset result type=\(String(describing: avAsset.map { type(of: $0) })) url=\(String(describing: (avAsset as? AVURLAsset)?.url.path)) info=\(String(describing: info))")
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }

    private static func stillOrientation(
        for asset: PHAsset,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> CGImagePropertyOrientation {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in progress(value) }
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { _, _, orientation, _ in
                continuation.resume(returning: orientation)
            }
        }
    }

    private static func stillImageURL(
        for asset: PHAsset,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> URL? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in progress(value) }
        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-still-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func pairedResources(for livePhoto: PHLivePhoto) -> (video: PHAssetResource?, photo: PHAssetResource?)? {
        let resources = PHAssetResource.assetResources(for: livePhoto)
        guard let video = resources.first(where: { $0.type == .pairedVideo }) else { return nil }
        let photo = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
        return (video, photo)
    }

    private static func writeResource(
        _ resource: PHAssetResource,
        progress: @escaping @Sendable (Double) -> Void,
        fileExtension: String? = nil
    ) async -> URL? {
        let ext = fileExtension ?? URL(fileURLWithPath: resource.originalFilename).pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-import-\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = progress
        let resourceName = resource.originalFilename
        let resourceType = resource.type.rawValue
        let error: Error? = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) {
                LogStore.log("xdz.import.resource.write result name=\(resourceName) type=\(resourceType) error=\(String(describing: $0))")
                continuation.resume(returning: $0)
            }
        }
        guard error == nil else {
            LogStore.log("xdz.import.resource.fail destination=\(destination.path) error=\(String(describing: error))")
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        guard byteCount > 0 else {
            LogStore.log("xdz.import.resource.fail destination=\(destination.path) reason=emptyFile")
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        LogStore.log("xdz.import.resource.ready destination=\(destination.path) bytes=\(byteCount)")
        return destination
    }

    private static func resourceData(
        _ resource: PHAssetResource,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Data? {
        guard let url = await writeResource(resource, progress: progress) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return await readData(at: url)
    }

    private static func copyToTemporaryFile(_ url: URL) async -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-import-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static func readData(at url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
    }

    private static func exifOrientation(of url: URL) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32 else { return nil }
        return CGImagePropertyOrientation(rawValue: raw)
    }
}

/// 视频文件的 Transferable 包装（PhotosPicker 加载到本地临时文件）。
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("LF-import-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}
