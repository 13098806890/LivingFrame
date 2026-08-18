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
    /// 素材文件夹（按创建时间倒序）
    @Published var folders: [LibraryFolder] = []

    // MARK: - 工程

    @Published var composition: Composition?
    /// 素材属性（边缘/风格等）变更版本号，用于触发画布重渲染
    @Published var clipStyleVersion = 0
    /// 画布上选中的元素（支持多选，primary 为最后点选的）
    @Published var selectedElementIDs: Set<UUID> = []
    @Published var lastSelectedElementID: UUID?
    @Published var selectedAudioID: UUID?
    /// 是否选中背景对象（点击画布空白处选中，检查器可编辑背景图案）
    @Published var selectedBackground = false
    /// 是否处于裁剪模式（画布显示裁剪框）
    @Published var isCropping = false

    /// 检查器主对象：单选时是该元素，多选时返回 nil
    var primarySelectedID: UUID? {
        selectedElementIDs.count == 1 ? selectedElementIDs.first : nil
    }

    /// 当前主选元素（工具行/检查器聚焦用）
    var primarySelectedElement: CompositionElement? {
        guard let id = primarySelectedID else { return nil }
        return composition?.elements.first { $0.id == id }
    }

    func isElementSelected(_ id: UUID) -> Bool {
        selectedElementIDs.contains(id)
    }

    /// 点选元素；additive 为 true 时追加多选（长按），否则单选
    func selectElement(_ id: UUID, additive: Bool = false) {
        if additive {
            if selectedElementIDs.contains(id) {
                selectedElementIDs.remove(id)
            } else {
                selectedElementIDs.insert(id)
            }
        } else {
            selectedElementIDs = [id]
        }
        lastSelectedElementID = id
        selectedAudioID = nil
        selectedBackground = false
    }

    /// 选中背景对象（点击画布空白处）
    func selectBackground() {
        selectedBackground = true
        selectedElementIDs.removeAll()
        lastSelectedElementID = nil
        selectedAudioID = nil
    }

    func clearElementSelection() {
        selectedElementIDs.removeAll()
        lastSelectedElementID = nil
        selectedBackground = false
    }

    // MARK: - 播放

    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    /// 倒序播放
    @Published var isReversed = false
    /// 循环播放（默认开）
    @Published var isLooping = true

    // MARK: - 导出

    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportedURL: URL?

    // MARK: - 作品

    @Published var works: [WorkItem] = []

    // MARK: - Tab

    /// 当前主 Tab（作品页"重新编辑"后自动切回编辑页）
    @Published var selectedTab: AppTab = .library

    // MARK: - Sheet 状态

    @Published var showEffectPicker = false
    @Published var showExportView = false

    // MARK: - 设置

    @Published var defaultFormat: ExportFormat = .gif {
        didSet { UserDefaults.standard.set(defaultFormat.rawValue, forKey: settingDefaultFormatKey) }
    }
    @Published var exportFPS: Double = 15 {
        didSet { UserDefaults.standard.set(exportFPS, forKey: settingExportFPSKey) }
    }
    @Published var maxDimension: Double = 1280 {
        didSet { UserDefaults.standard.set(maxDimension, forKey: settingMaxDimensionKey) }
    }
    /// 抠图处理帧率（低于源帧率时抽帧处理，帧数减少处理更快）
    @Published var processingFPS: Double = 30 {
        didSet { UserDefaults.standard.set(processingFPS, forKey: settingProcessingFPSKey) }
    }

    private let settingDefaultFormatKey = "setting.defaultFormat"
    private let settingExportFPSKey = "setting.exportFPS"
    private let settingMaxDimensionKey = "setting.maxDimension"
    private let settingProcessingFPSKey = "setting.processingFPS"

    // MARK: - 编辑交互

    /// 拖拽开始时的元素位置锚点
    var dragAnchor: CGPoint?

    private let worksStore = WorksStore()
    private let folderStore = LibraryFolderStore()
    private let audioEngine = AudioPreviewEngine()

    init() {
        works = worksStore.loadWorks()
        // 恢复持久化的素材与文件夹
        FrameCache.shared.reload()
        clips = FrameCache.shared.allClips()
        folders = folderStore.load()
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: settingDefaultFormatKey),
           let format = ExportFormat(rawValue: raw) {
            defaultFormat = format
        }
        if defaults.object(forKey: settingExportFPSKey) != nil {
            exportFPS = defaults.double(forKey: settingExportFPSKey)
        }
        if defaults.object(forKey: settingMaxDimensionKey) != nil {
            maxDimension = defaults.double(forKey: settingMaxDimensionKey)
        }
        if defaults.object(forKey: settingProcessingFPSKey) != nil {
            processingFPS = defaults.double(forKey: settingProcessingFPSKey)
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        LogStore.log("launch: device=\(machine) system=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) app=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")")
    }

    // MARK: - 素材

    func startSegmenting(url: URL, name: String, stillOrientation: CGImagePropertyOrientation = .up) async {
        isSegmenting = true
        segmentationProgress = 0
        segmentingName = name
        segmentationError = nil
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log("startSegmenting: name=\(name) url=\(url.path) size=\(size) stillOrientation=\(stillOrientation.rawValue)")
        do {
            let clip = try await VideoSegmentationPipeline().segmentVideo(
                at: url,
                name: name,
                maxDimension: maxDimension,
                maxFPS: processingFPS,
                stillOrientation: stillOrientation
            ) { [weak self] info in
                Task { @MainActor in self?.segmentationProgress = info.fraction }
            }
            addClip(clip)
            isSegmenting = false
        } catch {
            LogStore.log("startSegmenting failed: \(error)")
            isSegmenting = false
            segmentationProgress = 0
            segmentationError = error.localizedDescription
        }
    }

    func startPhotoSegmenting(cgImage: CGImage, name: String) async {
        isSegmenting = true
        segmentationProgress = 0
        segmentingName = name
        segmentationError = nil
        let maxDimension = maxDimension
        LogStore.log("startPhotoSegmenting: name=\(name) input=\(cgImage.width)x\(cgImage.height)")
        do {
            let clip = try await Task.detached(priority: .userInitiated) {
                try VideoSegmentationPipeline().segmentPhoto(
                    from: cgImage,
                    name: name,
                    maxDimension: maxDimension
                )
            }.value
            addClip(clip)
            isSegmenting = false
        } catch {
            LogStore.log("startPhotoSegmenting failed: \(error)")
            isSegmenting = false
            segmentationProgress = 0
            segmentationError = error.localizedDescription
        }
    }

    func removeClip(at offsets: IndexSet) {
        let removed = offsets.map { clips[$0] }
        clips.remove(atOffsets: offsets)
        for clip in removed {
            FrameCache.shared.removeClip(id: clip.id)
            removeClipReferences(from: clip.id)
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

    /// 删除单个素材（磁盘 + 文件夹 + 工程引用）
    func deleteClip(_ clipID: String) {
        clips.removeAll { $0.id == clipID }
        FrameCache.shared.removeClip(id: clipID)
        removeClipReferences(from: clipID)
        if var comp = composition {
            comp.elements.removeAll { element in
                if case .clip(let id) = element.kind { return id == clipID }
                return false
            }
            comp.audioClips.removeAll { $0.sourceID == clipID }
            composition = comp
        }
        syncAudioPreview()
    }

    /// 从所有文件夹中移除素材引用并持久化
    private func removeClipReferences(from clipID: String) {
        var changed = false
        for i in folders.indices where folders[i].clipIDs.contains(clipID) {
            folders[i].clipIDs.removeAll { $0 == clipID }
            changed = true
        }
        if changed { folderStore.save(folders) }
    }

    // MARK: - 文件夹

    /// 新建文件夹（parentID 为 nil 时创建在根层级）
    func createFolder(named name: String, inParent parentID: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !folders.contains(where: { $0.name == trimmed && $0.parentID == parentID }) else { return }
        folders.insert(LibraryFolder(name: trimmed, parentID: parentID), at: 0)
        folderStore.save(folders)
    }

    /// 删除文件夹：连同所有子孙文件夹一起删除（素材保留在素材库）
    func deleteFolder(_ folder: LibraryFolder) {
        let ids = folderAndDescendants(of: folder.id)
        folders.removeAll { ids.contains($0.id) }
        folderStore.save(folders)
    }

    /// 根层级文件夹
    func rootFolders() -> [LibraryFolder] {
        folders.filter { $0.parentID == nil }
    }

    /// 指定文件夹的子文件夹
    func childFolders(of folderID: String) -> [LibraryFolder] {
        folders.filter { $0.parentID == folderID }
    }

    /// 是否有子文件夹
    func hasChildFolders(_ folderID: String) -> Bool {
        folders.contains { $0.parentID == folderID }
    }

    /// 指定文件夹及其所有子孙文件夹的素材 ID 集合（编辑页按文件夹选素材时用）
    func clipIDs(includingChildrenOf folderID: String) -> Set<String> {
        var ids: Set<String> = []
        for id in folderAndDescendants(of: folderID) {
            if let folder = folders.first(where: { $0.id == id }) {
                ids.formUnion(folder.clipIDs)
            }
        }
        return ids
    }

    /// 收集文件夹本身及所有子孙 ID
    private func folderAndDescendants(of folderID: String) -> Set<String> {
        var result: Set<String> = [folderID]
        var queue = [folderID]
        while let current = queue.popLast() {
            for folder in folders where folder.parentID == current && !result.contains(folder.id) {
                result.insert(folder.id)
                queue.append(folder.id)
            }
        }
        return result
    }

    /// 将素材移入/移出文件夹（folderID 为 nil 表示移出）
    func moveClip(_ clipID: String, toFolder folderID: String?) {
        var changed = false
        for i in folders.indices {
            if folders[i].clipIDs.contains(clipID) {
                folders[i].clipIDs.removeAll { $0 == clipID }
                changed = true
            }
            if let folderID, folders[i].id == folderID, !folders[i].clipIDs.contains(clipID) {
                folders[i].clipIDs.append(clipID)
                changed = true
            }
        }
        if changed { folderStore.save(folders) }
    }

    /// 设置素材边缘效果（持久化到 clip.json）
    func setClipEdgeStyle(_ clipID: String, _ style: ClipEdgeStyle) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].edgeStyle = style
        FrameCache.shared.register(clips[index])
        clipStyleVersion += 1
    }

    /// 设置描边颜色（持久化到 clip.json）
    func setClipEdgeColor(_ clipID: String, _ hex: String) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].edgeColorHex = hex
        FrameCache.shared.register(clips[index])
        clipStyleVersion += 1
    }

    /// 设置描边粗细（持久化到 clip.json）
    func setClipEdgeThickness(_ clipID: String, _ thickness: EdgeThickness) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].edgeThickness = thickness
        FrameCache.shared.register(clips[index])
        clipStyleVersion += 1
    }

    /// 设置素材贴纸风格（持久化到 clip.json）
    func setClipStickerStyle(_ clipID: String, _ style: StickerStyle) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].stickerStyle = style
        FrameCache.shared.register(clips[index])
        clipStyleVersion += 1
    }

    /// 设置素材的排除帧（帧选择功能），持久化到 clip.json
    func setExcludedFrames(_ clipID: String, _ excluded: Set<Int>) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].excludedFrames = excluded
        FrameCache.shared.register(clips[index])
        clipStyleVersion += 1
    }

    // MARK: - 背景

    /// 设置背景为纯色
    func setBackground(color hex: String) {
        guard var comp = composition ?? defaultComposition() else { return }
        comp.background = BackgroundPreset(kind: .solid, topColor: hex, bottomColor: hex)
        composition = comp
    }

    /// 设置背景为预置图片
    func setBackground(preset fileName: String) {
        guard var comp = composition ?? defaultComposition() else { return }
        comp.background = BackgroundPreset(
            kind: .image, topColor: "FFFFFF", bottomColor: "FFFFFF", imageFileName: fileName
        )
        composition = comp
    }

    /// 设置背景为相册图片（写入 Backgrounds 目录后引用）
    func setBackground(imageData: Data) {
        guard let fileName = BackgroundStore.shared.saveUserImage(imageData) else { return }
        guard var comp = composition ?? defaultComposition() else { return }
        comp.background = BackgroundPreset(
            kind: .image, topColor: "FFFFFF", bottomColor: "FFFFFF", imageFileName: fileName
        )
        composition = comp
    }

    /// 在底层背景上叠加线条图案图层（保留当前底色/图片；nil = 清除叠加层）
    func setBackgroundPattern(_ style: BackgroundPatternStyle?) {
        guard var comp = composition ?? defaultComposition() else { return }
        comp.background.patternOverlay = style
        composition = comp
    }

    /// 设置元素级背景图案（垫在元素内容下层）
    func setElementBackground(_ elementID: UUID, _ style: BackgroundPatternStyle?) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == elementID }) else { return }
        comp.elements[index].backgroundPattern = style
        composition = comp
    }

    private func addClip(_ clip: SegmentedClip) {
        // 提取后只进入素材库，不自动加入画布（用户在编辑页自行添加）
        clips.insert(clip, at: 0)
        syncAudioPreview()
    }

    private func defaultComposition() -> Composition? {
        let comp = Composition(
            name: NSLocalizedString("我的动态照片", comment: "Default composition name"),
            canvas: CanvasSpec(width: 1920, height: 1080),
            duration: 0,
            fps: 30
        )
        composition = comp
        return comp
    }

    // MARK: - 画布比例

    /// 创建指定比例的画布工程
    func createComposition(aspect: CanvasAspect) {
        let size = aspect.canvasSize
        let comp = Composition(
            name: NSLocalizedString("我的动态照片", comment: "Default composition name"),
            canvas: CanvasSpec(width: size.width, height: size.height),
            duration: 0,
            fps: 30
        )
        composition = comp
    }

    /// 确保有一个默认工程（直接添加素材/背景时调用）
    func ensureComposition() {
        if composition == nil {
            _ = defaultComposition()
        }
    }

    /// 修改画布比例：元素位置按比例换算，保持相对布局
    func setCanvasAspect(_ aspect: CanvasAspect) {
        guard var comp = composition else { return }
        let oldSize = comp.canvasRect.size
        let newSize = aspect.canvasSize
        guard oldSize.width > 0, oldSize.height > 0 else { return }
        let sx = newSize.width / oldSize.width
        let sy = newSize.height / oldSize.height
        for index in comp.elements.indices {
            comp.elements[index].transform.position = CGPoint(
                x: comp.elements[index].transform.position.x * sx,
                y: comp.elements[index].transform.position.y * sy
            )
            comp.elements[index].transform.scale *= min(sx, sy)
        }
        comp.canvas = CanvasSpec(width: newSize.width, height: newSize.height)
        comp.cropRect = nil
        composition = comp
    }

    // MARK: - 裁剪

    /// 应用裁剪区域（画布坐标系；元素可超出画布，输出只保留该区域）
    func setCropRect(_ rect: CGRect) {
        guard var comp = composition else { return }
        guard rect.width >= 50, rect.height >= 50 else { return }
        comp.cropRect = rect
        composition = comp
    }

    /// 取消裁剪（恢复全画布）
    func resetCrop() {
        guard var comp = composition, comp.cropRect != nil else { return }
        comp.cropRect = nil
        composition = comp
    }

    // MARK: - 元素

    func updateElement(_ id: UUID, _ mutate: (inout CompositionElement) -> Void) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == id }) else { return }
        mutate(&comp.elements[index])
        comp.elements[index].transform = sanitizedTransform(comp.elements[index].transform)
        composition = comp
        recomputeDuration()
    }

    /// 时长跟随内容：总时长 = 所有元素结束时间 / 音频结束时间的最大者（自由放置，可重叠）
    private func recomputeDuration() {
        guard var comp = composition else { return }
        var maxEnd: TimeInterval = 0
        for e in comp.elements {
            if e.endTime.isFinite { maxEnd = max(maxEnd, e.endTime) }
        }
        for a in comp.audioClips {
            maxEnd = max(maxEnd, a.startTime + a.duration)
        }
        if comp.duration != maxEnd {
            comp.duration = maxEnd
            composition = comp
        }
    }

    /// 消毒变换值，防止 NaN/Inf 写入导致崩溃
    private func sanitizedTransform(_ transform: ElementTransform) -> ElementTransform {
        var t = transform
        var changed = false
        if !t.position.x.isFinite || !t.position.y.isFinite {
            t.position = CGPoint(x: composition?.canvas.width ?? 540, y: composition?.canvas.height ?? 960)
            changed = true
        }
        if !t.scale.isFinite || t.scale <= 0 {
            t.scale = 1
            changed = true
        }
        if !t.rotation.isFinite {
            t.rotation = 0
            changed = true
        }
        if changed {
            LogStore.log("updateElement: 检测到非有限变换值，已重置")
        }
        return t
    }

    func deleteElement(_ id: UUID) {
        guard var comp = composition else { return }
        comp.elements.removeAll { $0.id == id }
        composition = comp
        selectedElementIDs.remove(id)
        if lastSelectedElementID == id { lastSelectedElementID = nil }
    }

    func moveElementZ(_ id: UUID, up: Bool) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == id }) else { return }
        let neighbor = up ? index + 1 : index - 1
        guard comp.elements.indices.contains(neighbor) else { return }
        comp.elements.swapAt(index, neighbor)
        composition = comp
    }

    /// 添加文字元素（默认文本"双击编辑文字"，画布中央）
    @discardableResult
    func addTextElement() -> UUID? {
        guard var comp = composition ?? defaultComposition() else { return nil }
        let text = TextElement()
        comp.texts.append(text)
        let element = CompositionElement(
            kind: .text(textID: text.id.uuidString),
            name: "文字",
            transform: ElementTransform(
                position: CGPoint(x: comp.canvas.width / 2, y: comp.canvas.height / 2),
                scale: 1,
                rotation: 0
            ),
            zIndex: comp.elements.count,
            startTime: 0,
            endTime: comp.duration
        )
        comp.elements.append(element)
        composition = comp
        selectElement(element.id)
        return text.id
    }

    /// 更新文字内容/样式（渲染触发重绘）
    func updateText(_ textID: UUID, _ mutate: (inout TextElement) -> Void) {
        guard var comp = composition,
              let index = comp.texts.firstIndex(where: { $0.id == textID }) else { return }
        mutate(&comp.texts[index])
        composition = comp
    }

    /// 设置元素滤镜（nil = 原图）
    func setElementFilter(_ elementID: UUID, _ filter: ElementFilter?) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == elementID }) else { return }
        comp.elements[index].filter = filter
        composition = comp
    }

    /// 添加一个素材元素（从素材库）
    func addElementFromClip(_ clip: SegmentedClip) {
        addElementFromClipID(clip.id)
    }

    /// 按 ID 添加素材元素
    func addElementFromClipID(_ clipID: String) {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return }
        guard var comp = composition ?? defaultComposition() else { return }
        // 素材尺寸异常时给默认缩放，避免产生 Inf 变换导致渲染失败
        let scale: CGFloat
        if clip.width > 0, clip.height > 0 {
            scale = min(
                0.8 * comp.canvas.width / CGFloat(clip.width),
                0.8 * comp.canvas.height / CGFloat(clip.height)
            )
        } else {
            scale = 0.5
        }
        // 每个元素附加小幅偏移，避免多选时全部叠在画布中心
        let offset = CGFloat(comp.elements.count) * 30
        let element = CompositionElement(
            kind: .clip(clipID: clip.id),
            name: clip.name,
            transform: ElementTransform(
                position: CGPoint(
                    x: comp.canvas.width / 2 + offset,
                    y: comp.canvas.height / 2
                ),
                scale: scale.isFinite ? scale : 0.5,
                rotation: 0
            ),
            zIndex: comp.elements.count,  // 0,1,2,... 不会重复
            // 时间轴 = 素材播放时长（按倍速折算），起始时间为 0，
            // 之后可在时间轴上拖动起始/结束位置调整整体播放时间
            startTime: 0,
            endTime: clip.effectiveDuration.isFinite ? clip.effectiveDuration : 1
        )
        comp.elements.append(element)
        composition = comp
        selectElement(element.id)
        recomputeDuration()
    }

    /// 设置素材播放倍速（随时间轴素材的"自身时长÷倍速"自动重算时长）
    func setClipPlaybackSpeed(_ clipID: String, _ speed: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        guard clips[index].playbackSpeed != speed else { return }
        clips[index].playbackSpeed = speed
        FrameCache.shared.register(clips[index])
        // 引用该素材的元素结束时间 = 起始时间 + 素材有效时长
        if var comp = composition {
            for i in comp.elements.indices {
                if case .clip(let cid) = comp.elements[i].kind, cid == clipID,
                   let clip = clips.first(where: { $0.id == cid }) {
                    comp.elements[i].endTime = comp.elements[i].startTime + clip.effectiveDuration
                }
            }
            composition = comp
        }
        clipStyleVersion += 1
        recomputeDuration()
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
        recomputeDuration()
    }

    func updateAudio(_ id: UUID, _ mutate: (inout AudioClip) -> Void) {
        guard var comp = composition,
              let index = comp.audioClips.firstIndex(where: { $0.id == id }) else { return }
        let oldVolume = comp.audioClips[index].volume
        mutate(&comp.audioClips[index])
        composition = comp
        if isPlaying {
            if comp.audioClips[index].volume != oldVolume {
                // 播放中调音量：实时生效，不重建引擎（重建会打断当前播放）
                audioEngine.updateVolume(comp.audioClips[index].volume, for: id)
            } else {
                // 淡入淡出/时长等结构变化：重建引擎并从当前位置续播
                syncAudioPreview()
                audioEngine.play(from: currentTime)
            }
        } else {
            syncAudioPreview()
        }
    }

    func deleteAudio(_ id: UUID) {
        guard var comp = composition else { return }
        comp.audioClips.removeAll { $0.id == id }
        composition = comp
        if selectedAudioID == id { selectedAudioID = nil }
        syncAudioPreview()
        recomputeDuration()
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
        guard composition != nil else { return }
        isPlaying = true
        audioEngine.play(from: currentTime)
    }

    func pause() {
        isPlaying = false
        audioEngine.stop()
    }

    func seek(to time: Double) {
        let duration = composition?.duration ?? 0
        let clamped = duration.isFinite ? min(max(time, 0), duration) : max(time, 0)
        currentTime = clamped.isFinite ? clamped : 0
    }

    func tick() {
        guard isPlaying, let comp = composition, comp.fps > 0, comp.duration.isFinite else { return }
        // 时间轴以真实时间 1x 前进（编辑页播放时钟 20Hz，每 tick 前进 1/20s）。
        // 素材的快慢由各自 playbackSpeed 在渲染时折算，不再全局改 fps。
        let step = 0.05
        if isReversed {
            let next = currentTime - step
            if next <= 0 {
                if isLooping {
                    currentTime = comp.duration - step
                } else {
                    currentTime = 0
                    isPlaying = false
                }
            } else {
                currentTime = next
            }
        } else {
            let next = currentTime + step
            if next >= comp.duration {
                if isLooping {
                    currentTime = 0
                } else {
                    currentTime = comp.duration
                    isPlaying = false
                }
            } else {
                currentTime = next
            }
        }
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
        selectElement(element.id)
    }

    /// 添加动图贴纸：默认播放一次（烟花 9 帧 × 0.1s = 0.9s），
    /// 之后可在时间轴上拖动结束时间拉长（帧循环补满，不减速）
    func addSticker(_ stickerID: String) {
        guard var comp = composition ?? defaultComposition() else { return }
        let element = CompositionElement(
            kind: .decoration(decorationID: stickerID),
            name: NSLocalizedString("烟花", comment: "Sticker name"),
            transform: ElementTransform(
                position: CGPoint(x: comp.canvas.width / 2, y: comp.canvas.height / 2),
                scale: 1, rotation: 0
            ),
            zIndex: 60,
            startTime: 0,
            endTime: 0.9
        )
        comp.elements.append(element)
        composition = comp
        selectElement(element.id)
        recomputeDuration()
    }

    // MARK: - 导出

    func export(format: ExportFormat, fps: Double) async throws -> URL {
        guard let composition else { throw AppStateError.noComposition }
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }
        let start = Date()
        LogStore.log("export: start format=\(format.rawValue) fps=\(fps) duration=\(composition.duration)s elements=\(composition.elements.count) audioClips=\(composition.audioClips.count)")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-export-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)")
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
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log("export: done elapsed=\(Int(Date().timeIntervalSince(start)))s size=\(size) bytes")
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
        var comp = work.composition
        // 消毒历史工程中的非法变换值（NaN/Inf 会导致渲染失败）
        var sanitized = false
        for index in comp.elements.indices {
            let before = comp.elements[index].transform
            comp.elements[index].transform = sanitizedTransform(before)
            if comp.elements[index].transform != before { sanitized = true }
        }
        if sanitized {
            LogStore.log("reopen: 已修复工程中的非法变换值")
        }
        composition = comp
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

    /// 清理临时文件：素材（含文件夹内外的所有抠图结果）一律保留，只删导入/导出产生的临时文件
    func clearCache() {
        let tmp = FileManager.default.temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) {
            for item in items where item.lastPathComponent.hasPrefix("LF-") {
                try? FileManager.default.removeItem(at: item)
            }
        }
        LogStore.log("clearCache: 已清理临时文件，素材全部保留")
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

/// 主 Tab 枚举
enum AppTab: Hashable {
    case library, editor, works, settings
}
