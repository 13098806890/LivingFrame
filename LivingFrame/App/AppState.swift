import CoreGraphics
import Foundation
import LivingFrameCore
import Photos
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // MARK: - 素材

    @Published var clips: [SegmentedClip] = []
    @Published var isSegmenting = false
    @Published var segmentationProgress: Double = 0
    @Published var segmentingName = ""
    /// 抠图失败原因（nil 表示无错误）
    @Published var segmentationError: String?

    // MARK: - 工程

    @Published var composition: Composition?
    @Published var selectedElementID: UUID?
    @Published var selectedAudioID: UUID?

    // MARK: - 播放

    @Published var currentTime: Double = 0
    @Published var isPlaying = false

    // MARK: - 导出

    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportedURL: URL?

    // MARK: - 作品

    @Published var works: [WorkItem] = []

    // MARK: - Sheet 状态

    @Published var showTemplatePicker = false
    @Published var showEffectPicker = false
    @Published var showExportView = false

    // MARK: - 设置

    @Published var defaultFormat: ExportFormat = .gif
    @Published var exportFPS: Double = 15
    @Published var maxDimension: Double = 1280

    // MARK: - 编辑交互

    /// 拖拽开始时的元素位置锚点
    var dragAnchor: CGPoint?

    private let worksStore = WorksStore()
    private let audioEngine = AudioPreviewEngine()

    init() {
        works = worksStore.loadWorks()
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        LogStore.log("启动: device=\(machine) system=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) app=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")")
    }

    // MARK: - 素材

    func startSegmenting(url: URL, name: String, additionalRotation: CGFloat = 0) {
        isSegmenting = true
        segmentationProgress = 0
        segmentingName = name
        segmentationError = nil
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log("startSegmenting: name=\(name) url=\(url.path) size=\(size) additionalRotation=\(additionalRotation)")
        Task.detached {
            do {
                let clip = try await VideoSegmentationPipeline().segmentVideo(
                    at: url,
                    name: name,
                    maxDimension: self.maxDimension,
                    additionalRotation: additionalRotation
                ) { info in
                    Task { @MainActor in
                        self.segmentationProgress = info.fraction
                    }
                }
                await MainActor.run {
                    self.addClip(clip)
                    self.isSegmenting = false
                }
            } catch {
                LogStore.log("startSegmenting 失败: \(error)")
                await MainActor.run {
                    self.isSegmenting = false
                    self.segmentationProgress = 0
                    self.segmentationError = error.localizedDescription
                }
            }
        }
    }

    func startPhotoSegmenting(cgImage: CGImage, name: String) {
        isSegmenting = true
        segmentationProgress = 0
        segmentingName = name
        segmentationError = nil
        LogStore.log("startPhotoSegmenting: name=\(name) 输入尺寸=\(cgImage.width)x\(cgImage.height)")
        let maxDimension = maxDimension
        Task.detached {
            do {
                let clip = try VideoSegmentationPipeline().segmentPhoto(
                    from: cgImage,
                    name: name,
                    maxDimension: maxDimension
                )
                await MainActor.run {
                    self.addClip(clip)
                    self.isSegmenting = false
                }
            } catch {
                LogStore.log("startPhotoSegmenting 失败: \(error)")
                await MainActor.run {
                    self.isSegmenting = false
                    self.segmentationProgress = 0
                    self.segmentationError = error.localizedDescription
                }
            }
        }
    }

    func removeClip(at offsets: IndexSet) {
        let removed = offsets.map { clips[$0] }
        clips.remove(atOffsets: offsets)
        for clip in removed {
            FrameCache.shared.removeClip(id: clip.id)
            guard var comp = composition else { continue }
            comp.elements.removeAll { element in
                if case .clip(let clipID) = element.kind { return clipID == clip.id }
                return false
            }
            comp.audioClips.removeAll { $0.sourceID == clip.id }
            composition = comp
        }
        syncAudioPreview()
    }

    private func addClip(_ clip: SegmentedClip) {
        clips.insert(clip, at: 0)
        guard var comp = composition ?? defaultComposition() else { return }
        let scale = min(
            0.8 * comp.canvas.width / CGFloat(clip.width),
            0.8 * comp.canvas.height / CGFloat(clip.height)
        )
        let element = CompositionElement(
            kind: .clip(clipID: clip.id),
            name: clip.name,
            transform: ElementTransform(
                position: CGPoint(x: comp.canvas.width / 2, y: comp.canvas.height / 2),
                scale: scale,
                rotation: 0
            ),
            zIndex: max(comp.elements.count, 1),
            startTime: 0,
            endTime: comp.duration
        )
        comp.elements.append(element)
        comp.duration = max(comp.duration, clip.duration)
        composition = comp
        selectedElementID = element.id
        syncAudioPreview()
    }

    private func defaultComposition() -> Composition? {
        let comp = Composition(
            name: NSLocalizedString("我的动态照片", comment: "Default composition name"),
            canvas: CanvasSpec(width: 1080, height: 1440),
            duration: 3,
            fps: 30
        )
        composition = comp
        return comp
    }

    // MARK: - 元素

    func updateElement(_ id: UUID, _ mutate: (inout CompositionElement) -> Void) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == id }) else { return }
        mutate(&comp.elements[index])
        composition = comp
    }

    func deleteElement(_ id: UUID) {
        guard var comp = composition else { return }
        comp.elements.removeAll { $0.id == id }
        composition = comp
        if selectedElementID == id { selectedElementID = nil }
    }

    func moveElementZ(_ id: UUID, up: Bool) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == id }) else { return }
        let neighbor = up ? index + 1 : index - 1
        guard comp.elements.indices.contains(neighbor) else { return }
        comp.elements.swapAt(index, neighbor)
        composition = comp
    }

    /// 添加一个素材元素（从素材库）
    func addElementFromClip(_ clip: SegmentedClip) {
        guard var comp = composition ?? defaultComposition() else { return }
        let scale = min(
            0.8 * comp.canvas.width / CGFloat(clip.width),
            0.8 * comp.canvas.height / CGFloat(clip.height)
        )
        let element = CompositionElement(
            kind: .clip(clipID: clip.id),
            name: clip.name,
            transform: ElementTransform(
                position: CGPoint(x: comp.canvas.width / 2, y: comp.canvas.height / 2),
                scale: scale,
                rotation: 0
            ),
            zIndex: max(comp.elements.count, 1),
            startTime: 0,
            endTime: comp.duration
        )
        comp.elements.append(element)
        composition = comp
        selectedElementID = element.id
    }

    // MARK: - 音轨

    func addAudioClip(from clip: SegmentedClip) {
        guard clip.audioURL != nil, var comp = composition ?? defaultComposition() else { return }
        let audio = AudioClip(
            sourceID: clip.id,
            startTime: 0,
            duration: clip.duration,
            volume: 1
        )
        comp.audioClips.append(audio)
        composition = comp
        selectedAudioID = audio.id
        syncAudioPreview()
    }

    func updateAudio(_ id: UUID, _ mutate: (inout AudioClip) -> Void) {
        guard var comp = composition,
              let index = comp.audioClips.firstIndex(where: { $0.id == id }) else { return }
        mutate(&comp.audioClips[index])
        composition = comp
        syncAudioPreview()
    }

    func deleteAudio(_ id: UUID) {
        guard var comp = composition else { return }
        comp.audioClips.removeAll { $0.id == id }
        composition = comp
        if selectedAudioID == id { selectedAudioID = nil }
        syncAudioPreview()
    }

    private func syncAudioPreview() {
        guard let comp = composition else { return }
        audioEngine.configure(clips: comp.audioClips) { [weak self] sourceID in
            guard let self else { return nil }
            return self.clips.first(where: { $0.id == sourceID })?.loadAudioURL()
        }
    }

    // MARK: - 播放

    func play() {
        guard let comp = composition, !comp.elements.isEmpty else { return }
        isPlaying = true
        audioEngine.play(from: currentTime)
    }

    func pause() {
        isPlaying = false
        audioEngine.stop()
    }

    func seek(to time: Double) {
        currentTime = min(max(time, 0), composition?.duration ?? 0)
    }

    func tick() {
        guard isPlaying, let comp = composition else { return }
        let next = currentTime + 1.0 / comp.fps
        if next >= comp.duration {
            currentTime = 0
        } else {
            currentTime = next
        }
    }

    // MARK: - 模板

    func applyTemplate(_ template: MagicTemplate) {
        guard var comp = composition ?? defaultComposition() else { return }
        comp.templateID = template.id
        comp.name = template.name
        if let canvas = template.canvasPreset { comp.canvas = canvas }
        if let background = template.background { comp.background = background }
        // 重建装饰层
        comp.elements.removeAll { element in
            switch element.kind {
            case .decoration, .effect: true
            case .clip: false
            }
        }
        for decoration in template.decorations {
            comp.elements.append(CompositionElement(
                kind: .decoration(decorationID: decoration.decorationID),
                name: decoration.decorationID,
                transform: decoration.transform,
                zIndex: decoration.zIndex,
                startTime: 0,
                endTime: comp.duration
            ))
        }
        // 人物元素按预设摆放
        let personIndices = comp.elements.indices.filter { index in
            if case .clip = comp.elements[index].kind { return true }
            return false
        }
        for (offset, index) in personIndices.enumerated() {
            if template.elementLayouts.indices.contains(offset) {
                comp.elements[index].transform = template.elementLayouts[offset].transform
                comp.elements[index].zIndex = template.elementLayouts[offset].zIndex
            }
        }
        // 特效
        for effectID in template.effectPresets {
            comp.elements.append(CompositionElement(
                kind: .effect(effectID: effectID),
                name: effectID,
                transform: ElementTransform(
                    position: CGPoint(x: comp.canvas.width / 2, y: comp.canvas.height / 2),
                    scale: 1, rotation: 0
                ),
                zIndex: 60,
                startTime: 0,
                endTime: comp.duration
            ))
        }
        composition = comp
    }

    func addEffect(_ effectID: String) {
        guard var comp = composition ?? defaultComposition() else { return }
        let element = CompositionElement(
            kind: .effect(effectID: effectID),
            name: effectID,
            transform: ElementTransform(
                position: CGPoint(x: comp.canvas.width / 2, y: comp.canvas.height / 2),
                scale: 1, rotation: 0
            ),
            zIndex: 60,
            startTime: 0,
            endTime: comp.duration
        )
        comp.elements.append(element)
        composition = comp
        selectedElementID = element.id
    }

    // MARK: - 导出

    func export(format: ExportFormat, fps: Double) async throws -> URL {
        guard let composition else { throw AppStateError.noComposition }
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(composition.name)-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)")
        switch format {
        case .gif:
            try await GIFExporter().export(composition, to: url, fps: fps) { [weak self] value in
                Task { @MainActor in self?.exportProgress = value }
            }
        case .hevcAlpha, .h264:
            try await VideoExporter().export(
                composition,
                format: format,
                sourceResolver: { [weak self] sourceID in
                    self?.clips.first(where: { $0.id == sourceID })?.loadAudioURL()
                },
                to: url
            ) { [weak self] value in
                Task { @MainActor in self?.exportProgress = value }
            }
        case .livePhoto:
            let output = try await LivePhotoExporter().export(composition, to: url) { [weak self] value in
                Task { @MainActor in self?.exportProgress = value }
            }
            let authorized = await requestAddOnlyAuthorization()
            guard authorized else { throw AppStateError.photoLibraryDenied }
            try await saveLivePhoto(videoURL: output.videoURL, coverData: output.coverData)
        }
        exportedURL = url
        savePosterForWidget()
        return url
    }

    private func requestAddOnlyAuthorization() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func saveLivePhoto(videoURL: URL, coverData: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: coverData, options: nil)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
        }
    }

    // MARK: - 作品

    func saveCurrentToWorks() {
        guard let comp = composition,
              let poster = CompositionRenderer().render(comp, at: 0),
              let posterData = pngData(from: poster) else { return }
        let work = WorkItem(
            name: comp.name,
            composition: comp,
            posterData: posterData,
            format: defaultFormat
        )
        if (try? worksStore.save(work)) != nil {
            works = worksStore.loadWorks()
        }
    }

    func deleteWork(_ work: WorkItem) {
        worksStore.delete(work)
        works = worksStore.loadWorks()
    }

    func reopen(_ work: WorkItem) {
        composition = work.composition
        // 重新注册仍存在的缓存素材
        for clip in clips {
            FrameCache.shared.register(clip)
        }
    }

    // MARK: - Widget

    func savePosterForWidget() {
        guard let comp = composition,
              let poster = CompositionRenderer().render(comp, at: 0) else { return }
        FrameStore.savePoster(poster, title: comp.name)
    }

    // MARK: - 缓存

    func clearCache() {
        FrameCache.shared.removeAll()
        clips.removeAll()
        composition = nil
        syncAudioPreview()
    }

    var cacheSizeText: String {
        let bytes = FrameCache.shared.totalSizeBytes
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum AppStateError: LocalizedError {
    case noComposition
    case photoLibraryDenied

    var errorDescription: String? {
        switch self {
        case .noComposition: NSLocalizedString("还没有可导出的工程", comment: "Export error")
        case .photoLibraryDenied: NSLocalizedString("需要相册权限才能保存 Live Photo，请在设置中开启", comment: "Export error")
        }
    }
}
