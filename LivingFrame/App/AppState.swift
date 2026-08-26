import CoreGraphics
import Foundation
import LivingFrameCore
import Photos
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static func clampedExtractionDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 5 }
        return min(max(value, 3), 10)
    }

    // MARK: - 素材

    @Published var clips: [SegmentedClip] = []
    /// 用户导入的静态/动态背景图片，可在编辑页作为独立元素添加多次。
    @Published var backgroundMedia: [BackgroundMediaItem] = []
    @Published var isSegmenting = false
    @Published var segmentationProgress: Double = 0
    @Published var segmentingName = ""
    /// 抠图失败原因（nil 表示无错误）
    @Published var segmentationError: String?
    /// 素材文件夹（按创建时间倒序）
    @Published var folders: [LibraryFolder] = []

    // MARK: - 工程

    @Published var composition: Composition? {
        willSet {
            guard !isApplyingHistory,
                  !isCoalescingTimelineHistory,
                  !isCoalescingCanvasHistory,
                  let current = composition,
                  let next = newValue,
                  current != next else { return }
            undoStack.append(current)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
    }
    private var undoStack: [Composition] = []
    private var redoStack: [Composition] = []
    private var isApplyingHistory = false
    /// 时间轴一次拖拽会产生数十次位置更新；只在手势开始时保留一份撤销快照。
    private var isCoalescingTimelineHistory = false
    /// 画布手势同样使用单次撤销快照，不能按触摸采样点堆叠历史。
    private var isCoalescingCanvasHistory = false
    /// 供画布区判断是否应跳过高成本合成。时间轴仍然按手指位置逐帧更新。
    @Published private(set) var isTimelineEditing = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
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
    // MARK: - 导出

    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportedURL: URL?

    // MARK: - 作品

    @Published var works: [WorkItem] = []
    /// 当前编辑页来自哪个已保存作品。nil 表示尚未保存的新工程。
    @Published private(set) var editingWorkID: UUID?

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
    /// 单个视频/Live Photo 默认最多抠取的时长；超出部分从视频开头截断。
    @Published var maxExtractionDuration: Double = 5 {
        didSet {
            maxExtractionDuration = Self.clampedExtractionDuration(maxExtractionDuration)
            UserDefaults.standard.set(maxExtractionDuration, forKey: settingMaxExtractionDurationKey)
        }
    }
    /// 全局视觉皮肤；切换后所有使用 LF 语义色的页面会立即刷新。
    @Published var appTheme: AppTheme = .skyPetal {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: settingAppThemeKey)
            LF.apply(appTheme)
        }
    }

    private let settingDefaultFormatKey = "setting.defaultFormat"
    private let settingExportFPSKey = "setting.exportFPS"
    private let settingMaxDimensionKey = "setting.maxDimension"
    private let settingProcessingFPSKey = "setting.processingFPS"
    private let settingMaxExtractionDurationKey = "setting.maxExtractionDuration"
    private let settingAppThemeKey = "setting.appTheme"

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
        // 背景目录扫描会读取视频轨道和动图帧信息，放到后台避免启动时阻塞主线程。
        Task { [weak self] in
            let media = await Task.detached(priority: .utility) {
                BackgroundStore.shared.allUserMedia()
            }.value
            guard !Task.isCancelled else { return }
            self?.backgroundMedia = media
        }
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
        if defaults.object(forKey: settingMaxExtractionDurationKey) != nil {
            maxExtractionDuration = Self.clampedExtractionDuration(
                defaults.double(forKey: settingMaxExtractionDurationKey)
            )
        }
        if let rawTheme = defaults.string(forKey: settingAppThemeKey),
           let theme = AppTheme(rawValue: rawTheme) {
            appTheme = theme
        } else {
            LF.apply(appTheme)
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        LogStore.log("launch: device=\(machine) system=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) app=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")")
    }

    // MARK: - 素材

    func startSegmenting(
        url: URL,
        name: String,
        sourceStartTime: TimeInterval = 0,
        sourceEndTime: TimeInterval? = nil,
        stillOrientation: CGImagePropertyOrientation = .up
    ) async {
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
                startTime: sourceStartTime,
                maxDuration: sourceEndTime.map { max($0 - sourceStartTime, 0.1) } ?? maxExtractionDuration,
                stillOrientation: stillOrientation
            ) { [weak self] info in
                Task { @MainActor in self?.segmentationProgress = info.fraction }
            }
            addClip(clip)
            isSegmenting = false
        } catch is CancellationError {
            isSegmenting = false
            segmentationProgress = 0
        } catch SegmentationError.cancelled {
            isSegmenting = false
            segmentationProgress = 0
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
        } catch is CancellationError {
            isSegmenting = false
            segmentationProgress = 0
        } catch SegmentationError.cancelled {
            isSegmenting = false
            segmentationProgress = 0
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
        recomputeDuration()
        if let elements = composition?.elements {
            selectedElementIDs = selectedElementIDs.filter { id in elements.contains { $0.id == id } }
            if let lastSelectedElementID, !elements.contains(where: { $0.id == lastSelectedElementID }) {
                self.lastSelectedElementID = nil
            }
        }
        if let selectedAudioID,
           composition?.audioClips.contains(where: { $0.id == selectedAudioID }) != true {
            self.selectedAudioID = nil
        }
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
        recomputeDuration()
        if let elements = composition?.elements {
            selectedElementIDs = selectedElementIDs.filter { id in elements.contains { $0.id == id } }
            if let lastSelectedElementID, !elements.contains(where: { $0.id == lastSelectedElementID }) {
                self.lastSelectedElementID = nil
            }
        }
        if let selectedAudioID,
           composition?.audioClips.contains(where: { $0.id == selectedAudioID }) != true {
            self.selectedAudioID = nil
        }
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

    /// 设置整张画布的排除帧；与单个素材的帧选择相互独立。
    func setExcludedCompositionFrames(_ excluded: Set<Int>) {
        guard var comp = composition else { return }
        let valid = Set(excluded.filter { $0 >= 0 && $0 < comp.frameCount })
        guard comp.excludedCompositionFrames != valid else { return }
        comp.excludedCompositionFrames = valid
        composition = comp
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

    /// 刷新背景媒体列表。素材选择器导入相册图片后调用。
    func reloadBackgroundMedia() {
        backgroundMedia = BackgroundStore.shared.allUserMedia()
    }

    /// 保存一张相册图片/动态图片，返回可用于创建元素的媒体 ID。
    @discardableResult
    func importBackgroundMedia(
        data: Data,
        preferredFileExtension: String? = nil,
        isVideo: Bool = false
    ) -> String? {
        let id = isVideo
            ? BackgroundStore.shared.saveUserVideo(data, preferredFileExtension: preferredFileExtension)
            : BackgroundStore.shared.saveUserImage(data, preferredFileExtension: preferredFileExtension)
        guard let id else { return nil }
        reloadBackgroundMedia()
        return id
    }

    /// 添加一个背景图片元素。背景元素默认位于所有现有元素下方，并覆盖当前工程时长。
    func addBackgroundElement(mediaID: String) {
        guard let media = backgroundMedia.first(where: { $0.id == mediaID }),
              var comp = composition ?? defaultComposition() else { return }
        let settings = BackgroundElementSettings()
        let regionRect = backgroundRegionRect(settings.region, in: comp.canvasRect)
        // 动态背景的默认片段应当等于媒体自身完整播放时长，而不是已有工程时长。
        // 后续若需要循环或延长，交给用户在时间轴中显式调整。
        let duration = media.isAnimated
            ? max(media.duration, 0.1)
            : max(comp.duration, 1)
        let element = CompositionElement(
            kind: .background(backgroundID: media.id),
            name: media.name == media.id ? NSLocalizedString("背景图片", comment: "Background element") : media.name,
            transform: ElementTransform(
                position: CGPoint(x: regionRect.midX, y: regionRect.midY),
                scale: 1,
                rotation: 0
            ),
            zIndex: minimumElementZIndex(in: comp),
            startTime: 0,
            endTime: duration,
            backgroundSettings: settings
        )
        comp.elements.append(element)
        composition = comp
        selectElement(element.id)
        recomputeDuration()
    }

    func setBackgroundRegion(_ elementID: UUID, _ region: BackgroundRegion) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == elementID }),
              case .background = comp.elements[index].kind else { return }
        var settings = comp.elements[index].backgroundSettings ?? BackgroundElementSettings()
        settings.region = region
        comp.elements[index].backgroundSettings = settings
        let rect = backgroundRegionRect(region, in: comp.canvasRect)
        comp.elements[index].transform.position = CGPoint(x: rect.midX, y: rect.midY)
        composition = comp
        // 背景区域是画布视觉内容，不依赖时间轴状态；显式通知主画布重渲染。
        clipStyleVersion &+= 1
    }

    /// 设置分割数量；4 区会自动使用两条互相垂直、可独立平移的分割线。
    func setBackgroundSplitCount(_ elementID: UUID, _ count: BackgroundSplitCount) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == elementID }),
              case .background = comp.elements[index].kind else { return }
        var settings = comp.elements[index].backgroundSettings ?? BackgroundElementSettings()
        settings.splitCount = count
        // 2/4 分区的遮罩定义在完整画布上。清除旧的半区/四分之一区域值，
        // 让渲染、选框与命中测试都以同一个画布坐标系工作。
        settings.region = .full
        if count != .full {
            let maximum = count == .two ? 1 : 3
            settings.selectedPartition = min(max(settings.selectedPartition, 0), maximum)
        }
        comp.elements[index].backgroundSettings = settings
        comp.elements[index].transform.position = CGPoint(
            x: comp.canvasRect.midX,
            y: comp.canvasRect.midY
        )
        composition = comp
        clipStyleVersion &+= 1
    }

    /// 设置第一条分割线角度，并在常用角度附近自动磁吸。
    func setBackgroundDividerAngle(_ elementID: UUID, _ angle: CGFloat) {
        updateBackgroundElement(elementID) {
            $0.dividerAngle = snappedBackgroundAngle(angle)
        }
    }

    /// 沿自身法线平移一条背景分割线。offset 是相对当前画布可移动范围的比例。
    func setBackgroundDividerOffset(_ elementID: UUID, dividerIndex: Int, offset: CGFloat) {
        updateBackgroundElement(elementID) {
            let value = BackgroundDividerGeometry.clampedOffset(offset)
            if dividerIndex == 0 {
                $0.primaryDividerOffset = value
            } else {
                $0.secondaryDividerOffset = value
            }
        }
    }

    /// 选择中心分割线切出的区域。
    func setBackgroundPartition(_ elementID: UUID, _ partition: Int) {
        updateBackgroundElement(elementID) {
            let maximum = $0.splitCount == .four ? 3 : 1
            $0.selectedPartition = min(max(partition, 0), maximum)
        }
    }

    func setBackgroundEdgeStyle(_ elementID: UUID, _ style: BackgroundEdgeStyle) {
        updateBackgroundElement(elementID) { $0.edgeStyle = style }
    }

    func setBackgroundEdgeWidth(_ elementID: UUID, _ width: CanvasEdgeWidth) {
        updateBackgroundElement(elementID) { $0.edgeWidth = width }
    }

    /// 设置画布边框外观，并确保它在时间轴中拥有一个可排序图层。
    func setCanvasEdgeStyle(_ style: CanvasEdgeStyle) {
        guard var comp = composition else { return }
        comp.canvasEdgeStyle = style
        if style == .none {
            comp.elements.removeAll { element in
                if case .canvasEdge = element.kind { return true }
                return false
            }
            selectedElementIDs = selectedElementIDs.filter { id in
                comp.elements.contains { $0.id == id }
            }
            if let lastSelectedElementID,
               !comp.elements.contains(where: { $0.id == lastSelectedElementID }) {
                self.lastSelectedElementID = nil
            }
        } else {
            ensureCanvasEdgeElement(in: &comp)
        }
        composition = comp
        clipStyleVersion &+= 1
    }

    func setCanvasEdgeWidth(_ width: CanvasEdgeWidth) {
        guard var comp = composition else { return }
        comp.canvasEdgeWidth = width
        if comp.canvasEdgeStyle != .none {
            ensureCanvasEdgeElement(in: &comp)
        }
        composition = comp
        clipStyleVersion &+= 1
    }

    /// 把全局画布边框样式同步为一个可排序的时间轴元素。样式/宽度仍保存在
    /// Composition 上，元素只负责“它在第几层”和“覆盖整个工程时长”。
    @discardableResult
    private func ensureCanvasEdgeElement(in comp: inout Composition) -> UUID {
        if let index = comp.elements.firstIndex(where: { element in
            if case .canvasEdge = element.kind { return true }
            return false
        }) {
            comp.elements[index].startTime = 0
            comp.elements[index].endTime = max(comp.duration, 0.1)
            comp.elements[index].name = NSLocalizedString("画布边框", comment: "Canvas edge timeline element")
            return comp.elements[index].id
        }
        let element = CompositionElement(
            kind: .canvasEdge,
            name: NSLocalizedString("画布边框", comment: "Canvas edge timeline element"),
            zIndex: nextElementZIndex(in: comp),
            startTime: 0,
            endTime: max(comp.duration, 0.1)
        )
        comp.elements.append(element)
        return element.id
    }

    func setBackgroundCropScale(_ elementID: UUID, _ scale: CGFloat) {
        updateBackgroundElement(elementID) { $0.cropScale = min(max(scale, 1), 4) }
    }

    func setBackgroundCropOffset(_ elementID: UUID, _ offset: CGPoint) {
        updateBackgroundElement(elementID) { $0.cropOffset = offset }
    }

    /// 用户主动顺时针旋转背景图；导入时的 EXIF 方向已在解码层处理，不会重复计算。
    func rotateBackground90(_ elementID: UUID) {
        updateBackgroundElement(elementID) {
            $0.rotationQuarterTurns = ($0.rotationQuarterTurns + 1) % 4
        }
    }

    private func updateBackgroundElement(
        _ elementID: UUID,
        _ mutate: (inout BackgroundElementSettings) -> Void
    ) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == elementID }),
              case .background = comp.elements[index].kind else { return }
        var settings = comp.elements[index].backgroundSettings ?? BackgroundElementSettings()
        mutate(&settings)
        comp.elements[index].backgroundSettings = settings
        composition = comp
        // 分区、角度、边缘和取景等设置都只在 backgroundSettings 内变化。单独递增
        // 视觉版本，避免 SwiftUI 合并 composition 发布或时间轴交互期间跳过刷新时，
        // 画布停留在旧分区，直到其它元素改动才被动更新。
        clipStyleVersion &+= 1
    }

    private func snappedBackgroundAngle(_ angle: CGFloat) -> CGFloat {
        let safeAngle = angle.isFinite ? angle : 90
        let normalized = safeAngle.truncatingRemainder(dividingBy: 180)
        let value = normalized < 0 ? normalized + 180 : normalized
        let snapAngles: [CGFloat] = [0, 30, 45, 60, 90, 120, 135, 150]
        guard let nearest = snapAngles.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) <= 6 else {
            return value
        }
        return nearest
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
        editingWorkID = nil
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
        editingWorkID = nil
        composition = comp
    }

    /// 确保有一个默认工程（直接添加素材/背景时调用）
    func ensureComposition() {
        if composition == nil {
            _ = defaultComposition()
        }
        guard var comp = composition, comp.canvasEdgeStyle != .none else { return }
        let hasEdge = comp.elements.contains { element in
            if case .canvasEdge = element.kind { return true }
            return false
        }
        guard !hasEdge else { return }
        _ = ensureCanvasEdgeElement(in: &comp)
        composition = comp
    }

    /// 修改画布比例：以画布中心为锚点，等比缩放元素的位置和大小，避免纵横轴分别缩放造成偏移
    func setCanvasAspect(_ aspect: CanvasAspect) {
        guard var comp = composition else { return }
        let oldSize = comp.canvasRect.size
        let newSize = aspect.canvasSize
        guard oldSize.width > 0, oldSize.height > 0 else { return }
        let sx = newSize.width / oldSize.width
        let sy = newSize.height / oldSize.height
        let contentScale = min(sx, sy)
        let oldCenter = CGPoint(x: oldSize.width / 2, y: oldSize.height / 2)
        let newCenter = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
        for index in comp.elements.indices {
            let position = comp.elements[index].transform.position
            comp.elements[index].transform.position = CGPoint(
                x: newCenter.x + (position.x - oldCenter.x) * contentScale,
                y: newCenter.y + (position.y - oldCenter.y) * contentScale
            )
            comp.elements[index].transform.scale *= contentScale
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

    func updateElement(
        _ id: UUID,
        _ mutate: (inout CompositionElement) -> Void,
        recomputeDuration shouldRecomputeDuration: Bool = true
    ) {
        guard var comp = composition,
              let index = comp.elements.firstIndex(where: { $0.id == id }) else { return }
        mutate(&comp.elements[index])
        comp.elements[index].transform = sanitizedTransform(comp.elements[index].transform)
        composition = comp
        if shouldRecomputeDuration { recomputeDuration() }
    }

    /// 开始一次时间轴直接操作。高频位置更新会合并成一条可撤销记录，
    /// 避免拖动时不断复制整个工程与触发画布重渲染。
    func beginTimelineEdit() {
        guard !isTimelineEditing else { return }
        if let composition {
            undoStack.append(composition)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            isCoalescingTimelineHistory = true
        }
        isTimelineEditing = true
    }

    /// 结束时间轴直接操作；随后由调用方一次性重算时长、同步预览。
    func finishTimelineEdit() {
        isCoalescingTimelineHistory = false
        isTimelineEditing = false
    }

    func beginCanvasEdit() {
        guard !isCoalescingCanvasHistory else { return }
        if let composition {
            undoStack.append(composition)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        isCoalescingCanvasHistory = true
    }

    func finishCanvasEdit() {
        isCoalescingCanvasHistory = false
    }

    /// 时长跟随内容：总时长 = 所有元素结束时间 / 音频结束时间的最大者（自由放置，可重叠）
    func recomputeDuration(autoFillOverlayElements: Bool = true) {
        guard var comp = composition else { return }
        let previousDuration = comp.duration
        var maxEnd: TimeInterval = 0
        var autoFillStickerIndices: [Int] = []
        var autoFillBackgroundIndices: [Int] = []
        for e in comp.elements {
            if case .canvasEdge = e.kind { continue }
            if e.endTime.isFinite { maxEnd = max(maxEnd, e.endTime) }
        }
        for a in comp.audioClips {
            maxEnd = max(maxEnd, a.startTime + a.duration)
        }

        // 贴纸若正好贴着上一次工程末端，视为“默认铺满”而非独立撑长工程。
        // 先从内容最大时长中排除它，之后再让它跟随新的工程末端一起伸缩。
        if autoFillOverlayElements, previousDuration.isFinite, previousDuration > 0 {
            for index in comp.elements.indices {
                guard case .decoration = comp.elements[index].kind,
                      abs(comp.elements[index].endTime - previousDuration) <= 0.001 else { continue }
                autoFillStickerIndices.append(index)
            }
            for index in comp.elements.indices {
                guard case .background = comp.elements[index].kind,
                      abs(comp.elements[index].endTime - previousDuration) <= 0.001 else { continue }
                autoFillBackgroundIndices.append(index)
            }
        }

        if !autoFillStickerIndices.isEmpty || !autoFillBackgroundIndices.isEmpty {
            let autoFillStickerSet = Set(autoFillStickerIndices)
            let autoFillBackgroundSet = Set(autoFillBackgroundIndices)
            maxEnd = 0
            for (index, element) in comp.elements.enumerated()
                where !autoFillStickerSet.contains(index) &&
                      !autoFillBackgroundSet.contains(index) &&
                      element.endTime.isFinite {
                maxEnd = max(maxEnd, element.endTime)
            }
            for audio in comp.audioClips {
                maxEnd = max(maxEnd, audio.startTime + audio.duration)
            }
            for index in autoFillStickerIndices {
                guard case .decoration(let decorationID) = comp.elements[index].kind else { continue }
                let minimumDuration = DecorationRenderer.stickerDefinition(for: decorationID)?.defaultDuration ?? 0.1
                comp.elements[index].endTime = max(maxEnd, minimumDuration)
            }
            for index in autoFillBackgroundIndices {
                comp.elements[index].endTime = max(maxEnd, 0.1)
            }
            maxEnd = max(
                maxEnd,
                autoFillStickerIndices.compactMap { comp.elements[$0].endTime }.max() ?? 0,
                autoFillBackgroundIndices.compactMap { comp.elements[$0].endTime }.max() ?? 0
            )
        }

        // 贴纸默认铺满时间轴：当素材把工程时长向右撑长时，仍处于旧时间轴末端的贴纸
        // 自动跟随延长；已经缩短到旧末端之前的贴纸则视为用户手动调整，不强行改动。
        if autoFillOverlayElements, maxEnd > previousDuration + 0.001 {
            for index in comp.elements.indices {
                guard case .decoration = comp.elements[index].kind,
                      comp.elements[index].endTime <= previousDuration + 0.001 else { continue }
                comp.elements[index].endTime = maxEnd
            }
            for index in comp.elements.indices {
                guard case .background = comp.elements[index].kind,
                      comp.elements[index].endTime <= previousDuration + 0.001 else { continue }
                comp.elements[index].endTime = maxEnd
            }
        }

        if let edgeIndex = comp.elements.firstIndex(where: { element in
            if case .canvasEdge = element.kind { return true }
            return false
        }) {
            // 边框是工程级图层，永远覆盖完整工程时长，不额外撑长工程。
            comp.elements[edgeIndex].startTime = 0
            comp.elements[edgeIndex].endTime = max(maxEnd, 0.1)
        }
        if comp.duration != maxEnd {
            comp.duration = maxEnd
            composition = comp
        } else if autoFillOverlayElements, maxEnd > previousDuration + 0.001 {
            composition = comp
        }
        if currentTime > maxEnd {
            currentTime = maxEnd
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
        let deletingCanvasEdge = comp.elements.contains { element in
            guard element.id == id else { return false }
            if case .canvasEdge = element.kind { return true }
            return false
        }
        comp.elements.removeAll { $0.id == id }
        if deletingCanvasEdge {
            comp.canvasEdgeStyle = .none
        }
        composition = comp
        selectedElementIDs.remove(id)
        if lastSelectedElementID == id { lastSelectedElementID = nil }
        recomputeDuration()
    }

    private func nextElementZIndex(in composition: Composition) -> Int {
        let normalElements = composition.elements.filter { element in
            if case .canvasEdge = element.kind { return false }
            return true
        }
        let normalMax = normalElements.map(\.zIndex).max() ?? -1
        // 默认边框保持在普通内容之上，延续旧版“边框覆盖所有内容”的观感；
        // 用户若已在时间轴把边框放到普通元素下方，新添加内容则正常放到最上层。
        if let edgeZ = composition.elements.first(where: { element in
            if case .canvasEdge = element.kind { return true }
            return false
        })?.zIndex, edgeZ >= normalMax {
            return edgeZ - 1
        }
        return normalMax + 1
    }

    private func minimumElementZIndex(in composition: Composition) -> Int {
        (composition.elements.map(\.zIndex).min() ?? 0) - 1
    }

    private func backgroundRegionRect(_ region: BackgroundRegion, in canvas: CGRect) -> CGRect {
        switch region {
        case .full, .diagonal:
            return canvas
        case .upperHalf:
            return CGRect(x: canvas.minX, y: canvas.midY, width: canvas.width, height: canvas.height / 2)
        case .lowerHalf:
            return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: canvas.height / 2)
        case .quarter:
            return CGRect(x: canvas.midX, y: canvas.midY, width: canvas.width / 2, height: canvas.height / 2)
        }
    }

    /// 新增长素材时，让仍处于默认时长的动图贴纸覆盖新的工程时长并循环播放。
    /// 已经手动调整过时间轴的贴纸不强行改动，保留用户的裁剪选择。
    private func extendDefaultStickerDurations(in composition: inout Composition, to duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        for index in composition.elements.indices {
            guard case .decoration(let decorationID) = composition.elements[index].kind,
                  let defaultDuration = DecorationRenderer.stickerDefinition(for: decorationID)?.defaultDuration,
                  composition.elements[index].endTime <= defaultDuration + 0.001 else { continue }
            composition.elements[index].endTime = max(composition.elements[index].endTime, duration)
        }
    }

    /// 清空当前编辑页内容；不删除素材库中的素材，也保留画布比例和背景设置。
    func clearEditorContent() {
        guard var comp = composition else { return }
        pause()
        comp.elements.removeAll()
        comp.audioClips.removeAll()
        comp.texts.removeAll()
        comp.duration = 0
        if comp.canvasEdgeStyle != .none {
            _ = ensureCanvasEdgeElement(in: &comp)
        }
        composition = comp
        selectedElementIDs.removeAll()
        lastSelectedElementID = nil
        selectedAudioID = nil
        selectedBackground = false
        isCropping = false
        currentTime = 0
        syncAudioPreview()
    }

    func moveElementZ(_ id: UUID, up: Bool) {
        guard var comp = composition else { return }
        var ordered = comp.elements.sorted { $0.zIndex < $1.zIndex }
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let neighbor = up ? index + 1 : index - 1
        guard ordered.indices.contains(neighbor) else { return }
        ordered.swapAt(index, neighbor)
        for (zIndex, element) in ordered.enumerated() {
            guard let originalIndex = comp.elements.firstIndex(where: { $0.id == element.id }) else { continue }
            comp.elements[originalIndex].zIndex = zIndex
        }
        composition = comp
    }

    /// 按“画布最上层 → 最下层”的顺序一次性重排元素层级。
    /// 时间轴拖拽使用稳定的元素 ID 顺序提交，避免拖动经过多行时逐次交换造成跳动。
    func setElementLayerOrder(topToBottom elementIDs: [UUID]) {
        guard var comp = composition,
              elementIDs.count == comp.elements.count,
              Set(elementIDs) == Set(comp.elements.map(\.id)) else { return }

        let highestZIndex = elementIDs.count - 1
        for (displayIndex, id) in elementIDs.enumerated() {
            guard let elementIndex = comp.elements.firstIndex(where: { $0.id == id }) else { continue }
            comp.elements[elementIndex].zIndex = highestZIndex - displayIndex
        }
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
            zIndex: nextElementZIndex(in: comp),
            startTime: 0,
            endTime: max(comp.duration, 1)
        )
        comp.elements.append(element)
        composition = comp
        selectElement(element.id)
        recomputeDuration()
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
            zIndex: nextElementZIndex(in: comp),
            // 时间轴 = 素材播放时长（按倍速折算），起始时间为 0，
            // 之后可在时间轴上拖动起始/结束位置调整整体播放时间
            startTime: 0,
            endTime: clip.effectiveDuration.isFinite ? clip.effectiveDuration : 1,
            sourceStartTime: 0,
            sourceEndTime: clip.activeDuration.isFinite ? clip.activeDuration : 1
        )
        comp.elements.append(element)
        extendDefaultStickerDurations(in: &comp, to: max(comp.duration, element.endTime))
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
        // 引用该素材的元素结束时间 = 起始时间 + 当前源范围时长 / 倍速
        if var comp = composition {
            for i in comp.elements.indices {
                if case .clip(let cid) = comp.elements[i].kind, cid == clipID,
                   let clip = clips.first(where: { $0.id == cid }) {
                    let sourceDuration = max(clip.activeDuration, 0.001)
                    let sourceStart = min(max(comp.elements[i].sourceStartTime, 0), sourceDuration)
                    let sourceEnd = comp.elements[i].sourceEndTime.isFinite
                        ? min(max(comp.elements[i].sourceEndTime, sourceStart), sourceDuration)
                        : sourceDuration
                    comp.elements[i].sourceStartTime = sourceStart
                    comp.elements[i].sourceEndTime = sourceEnd
                    comp.elements[i].endTime = comp.elements[i].startTime
                        + max((sourceEnd - sourceStart) / max(speed, 0.01), 0.1)
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

    func updateAudio(
        _ id: UUID,
        _ mutate: (inout AudioClip) -> Void,
        syncPreview shouldSyncPreview: Bool = true
    ) {
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
                if shouldSyncPreview { syncAudioPreview() }
                audioEngine.play(from: currentTime)
            }
        } else if shouldSyncPreview {
            syncAudioPreview()
        }
        if shouldSyncPreview { recomputeDuration() }
    }

    /// 时间轴拖拽结束后一次性同步音频预览和工程时长。
    func finishAudioEdit() {
        syncAudioPreview()
        recomputeDuration()
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
        guard let comp = composition, comp.duration > 0 else { return }
        // 播放完成后再次点击，从对应方向的端点重新开始，但每次只播放一遍。
        if isReversed {
            if currentTime <= 0 { currentTime = comp.duration }
        } else if currentTime >= comp.duration {
            currentTime = 0
        }
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

    /// 播放由画布渲染驱动：一帧完整合成完成后才调用一次。
    func tick(delta: TimeInterval = 0.05) {
        guard isPlaying, let comp = composition, comp.fps > 0, comp.duration.isFinite else { return }
        // 使用实际渲染间隔推进时间，不再让独立 Timer 超过预览渲染速度。
        let step = min(max(delta.isFinite ? delta : 0.05, 0.001), 0.25)
        if isReversed {
            let next = currentTime - step
            if next <= 0 {
                currentTime = 0
                isPlaying = false
                audioEngine.stop()
            } else {
                currentTime = next
            }
        } else {
            let next = currentTime + step
            if next >= comp.duration {
                // 播放完成后回到第一帧，方便用户立即再次预览或继续编辑。
                currentTime = 0
                isPlaying = false
                audioEngine.stop()
            } else {
                currentTime = next
            }
        }
    }

    func undo() {
        guard let previous = undoStack.popLast(), let current = composition else { return }
        redoStack.append(current)
        isApplyingHistory = true
        composition = previous
        isApplyingHistory = false
        currentTime = min(currentTime, previous.duration)
        LogStore.log("history.undo elements=\(previous.elements.count)")
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = composition else { return }
        undoStack.append(current)
        isApplyingHistory = true
        composition = next
        isApplyingHistory = false
        currentTime = min(currentTime, next.duration)
        LogStore.log("history.redo elements=\(next.elements.count)")
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
            zIndex: nextElementZIndex(in: comp),
            startTime: 0,
            endTime: max(comp.duration, 1)
        )
        comp.elements.append(element)
        composition = comp
        selectElement(element.id)
        recomputeDuration()
    }

    /// 添加动图贴纸：默认覆盖当前工程时长，帧序列不足时循环补满。
    /// 之后仍可在时间轴上拖动结束时间调整播放区间。
    func addSticker(_ stickerID: String) {
        guard var comp = composition ?? defaultComposition() else { return }
        let stickerDuration = DecorationRenderer.stickerDefinition(for: stickerID)?.defaultDuration ?? 0.9
        let element = CompositionElement(
            kind: .decoration(decorationID: stickerID),
            name: DecorationRenderer.stickerName(for: stickerID),
            transform: ElementTransform(
                position: CGPoint(x: comp.canvas.width / 2, y: comp.canvas.height / 2),
                scale: 1, rotation: 0
            ),
            zIndex: nextElementZIndex(in: comp),
            startTime: 0,
            endTime: max(comp.duration, stickerDuration)
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
        RenderMemoryController.prepareForExport()
        defer {
            RenderMemoryController.finishExport()
            isExporting = false
        }
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
                to: url,
                fps: fps
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

    /// 只有用户在编辑页主动点击“保存”时调用。再次保存已打开的作品会更新原记录。
    @discardableResult
    func saveCurrentToWorks() async -> Bool {
        guard let comp = composition else { return false }
        let posterData = await Task.detached(priority: .utility) {
            guard let poster = CompositionRenderer(frameMaxPixelSize: 900).render(comp, at: 0) else {
                return Data?.none
            }
            return pngData(from: poster)
        }.value
        guard let posterData else {
            LogStore.log("work.save failed: poster render returned nil")
            return false
        }
        let existing = editingWorkID.flatMap { id in works.first { $0.id == id } }
        let now = Date()
        let referencedClipIDs = Set(comp.elements.compactMap { element -> String? in
            guard case .clip(let clipID) = element.kind else { return nil }
            return clipID
        })
        let clipSettings = clips
            .filter { referencedClipIDs.contains($0.id) }
            .map {
                WorkClipSettings(
                    clipID: $0.id,
                    edgeStyle: $0.edgeStyle,
                    edgeLineStyle: $0.edgeLineStyle,
                    edgeThickness: $0.edgeThickness,
                    edgeColorHex: $0.edgeColorHex,
                    stickerStyle: $0.stickerStyle,
                    playbackSpeed: $0.playbackSpeed,
                    excludedFrames: $0.excludedFrames
                )
            }
        let work = WorkItem(
            id: existing?.id ?? UUID(),
            name: comp.name,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            composition: comp,
            clipSettings: clipSettings,
            posterData: posterData,
            format: existing?.format ?? defaultFormat
        )
        do {
            try worksStore.save(work)
            editingWorkID = work.id
            works = worksStore.loadWorks()
            LogStore.log("work.save done id=\(work.id) updated=\(existing != nil)")
            return true
        } catch {
            LogStore.log("work.save failed: \(error)")
            return false
        }
    }

    func deleteWork(_ work: WorkItem) {
        worksStore.delete(work)
        if editingWorkID == work.id { editingWorkID = nil }
        works = worksStore.loadWorks()
    }

    func reopen(_ work: WorkItem) {
        restoreClipSettings(from: work)
        var comp = work.composition
        migrateClipSourceRanges(in: &comp)
        if comp.canvasEdgeStyle != .none {
            _ = ensureCanvasEdgeElement(in: &comp)
        }
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
        pause()
        isApplyingHistory = true
        composition = comp
        isApplyingHistory = false
        undoStack.removeAll()
        redoStack.removeAll()
        editingWorkID = work.id
        currentTime = 0
        selectedElementIDs.removeAll()
        lastSelectedElementID = nil
        selectedAudioID = nil
        selectedBackground = true
        isCropping = false
        // 重新注册仍存在的缓存素材
        for clip in clips {
            FrameCache.shared.register(clip)
        }
        clipStyleVersion += 1
    }

    private func restoreClipSettings(from work: WorkItem) {
        for settings in work.clipSettings ?? [] {
            guard let index = clips.firstIndex(where: { $0.id == settings.clipID }) else { continue }
            clips[index].edgeStyle = settings.edgeStyle
            clips[index].edgeLineStyle = settings.edgeLineStyle
            clips[index].edgeThickness = settings.edgeThickness
            clips[index].edgeColorHex = settings.edgeColorHex
            clips[index].stickerStyle = settings.stickerStyle
            clips[index].playbackSpeed = settings.playbackSpeed
            clips[index].excludedFrames = settings.excludedFrames
        }
    }

    /// 为旧版本工程补齐素材源范围。
    /// 旧版本只有时间轴 start/end，默认从素材第 0 帧开始播放；保留这个行为，
    /// 同时把源出点限制到旧工程实际播放的素材时长，避免打开工程后画面突然变化。
    private func migrateClipSourceRanges(in comp: inout Composition) {
        for index in comp.elements.indices {
            guard case .clip(let clipID) = comp.elements[index].kind,
                  let clip = clips.first(where: { $0.id == clipID }) else { continue }

            let sourceDuration = max(clip.activeDuration, 0.001)
            let speed = max(clip.playbackSpeed, 0.01)
            if !comp.elements[index].sourceEndTime.isFinite {
                let oldTimelineDuration = max(
                    comp.elements[index].endTime - comp.elements[index].startTime,
                    1 / max(clip.fps, 1)
                )
                comp.elements[index].sourceStartTime = 0
                comp.elements[index].sourceEndTime = min(sourceDuration, oldTimelineDuration * speed)
            } else {
                comp.elements[index].sourceStartTime = min(
                    max(comp.elements[index].sourceStartTime, 0),
                    sourceDuration
                )
                comp.elements[index].sourceEndTime = min(
                    max(comp.elements[index].sourceEndTime, comp.elements[index].sourceStartTime),
                    sourceDuration
                )
            }
        }
    }

    // MARK: - Widget

    func savePosterForWidget() {
        guard let comp = composition,
              let poster = CompositionRenderer().render(comp, at: 0) else { return }
        FrameStore.savePoster(poster, title: comp.name)
    }

    /// 从作品快照生成 Widget 封面，不改变当前编辑页中的工程。
    func savePosterForWidget(_ work: WorkItem) {
        guard let poster = UIImage(data: work.posterData)?.cgImage else { return }
        FrameStore.savePoster(poster, title: work.name)
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
