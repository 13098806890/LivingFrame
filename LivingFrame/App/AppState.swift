import CoreGraphics
import Foundation
import LivingFrameCore
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// 作品文件的唯一写入入口。actor 保证保存、复制、重命名和删除按调用顺序执行，
/// 避免多个后台任务互相覆盖，也让磁盘操作脱离主线程。
private actor WorkPersistenceCoordinator {
    private let store: WorksStore

    init(store: WorksStore) {
        self.store = store
    }

    func saveAndLoad(_ work: WorkItem) -> (Bool, [WorkItem]) {
        do {
            try store.save(work)
            return (true, store.loadWorks())
        } catch {
            LogStore.log("work.save failed: \(error)")
            return (false, [])
        }
    }

    func load() -> [WorkItem] {
        store.loadWorks()
    }

    func save(_ work: WorkItem, failureMessage: String) -> Bool {
        do {
            try store.save(work)
            return true
        } catch {
            LogStore.log("\(failureMessage): \(error)")
            return false
        }
    }

    func delete(_ work: WorkItem) {
        store.delete(work)
    }
}

@MainActor
final class AppState: ObservableObject {
    static let processingFPSOptions: [Double] = [10, 15, 30, 60]

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
    /// 导出完成后的非错误提示（例如微信收藏模式为满足体积而均匀抽帧）。
    @Published private(set) var exportNotice: String?
    /// 素材文件夹（按创建时间倒序）
    @Published var folders: [LibraryFolder] = []
    /// 设置页展示的素材占用；异步计算，避免每次 SwiftUI 刷新都扫描磁盘。
    @Published private(set) var cacheSizeText = "计算中…"

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
        didSet {
            hasUnsavedChanges = composition != cleanCompositionSnapshot
            if hasUnsavedChanges {
                scheduleDraftAutosave()
            } else {
                autosaveTask?.cancel()
            }
        }
    }
    /// 当前工程是否有尚未保存到“作品”的修改。
    @Published private(set) var hasUnsavedChanges = false
    /// 编辑中的草稿是否正在后台自动保存。
    @Published private(set) var isAutosavingDraft = false
    /// 最近一次自动保存失败时的提示；下一次编辑会重新尝试保存。
    @Published private(set) var autosaveError: String?
    private var cleanCompositionSnapshot: Composition?
    private var undoStack: [Composition] = []
    private var redoStack: [Composition] = []
    private var autosaveTask: Task<Void, Never>?
    /// 自动保存任务可以在渲染封面或写盘期间继续运行；序号用于忽略已经过期任务的结果。
    private var autosaveGeneration = 0
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
    @Published private(set) var isLoadingWorks = true
    /// 当前编辑页来自哪个已保存作品。nil 表示尚未保存的新工程。
    @Published private(set) var editingWorkID: UUID?
    /// 正式保存的进行中状态；自动保存草稿使用独立的 isAutosavingDraft。
    @Published private(set) var isSavingWork = false
    /// 手动保存失败时的错误提示。
    @Published private(set) var saveError: String?

    /// 当前作品是否已有自动保存的草稿。
    var currentWorkHasDraft: Bool {
        guard let editingWorkID else { return false }
        return works.first(where: { $0.id == editingWorkID })?.draft != nil
    }

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

    /// 当前工程引用的动态素材中，最高的实际提取帧率。
    /// 静态素材只有一帧，不参与导出帧率上限计算。
    var maximumSourceFPS: Double {
        guard let composition else { return 30 }
        let dynamicFPS = composition.elements.compactMap { element -> Double? in
            guard case .clip(let clipID) = element.kind,
                  let clip = FrameCache.shared.clip(id: clipID) ?? clips.first(where: { $0.id == clipID }),
                  clip.frameCount > 1,
                  clip.fps.isFinite,
                  clip.fps > 0 else {
                return nil
            }
            return clip.fps
        }
        return max(dynamicFPS.max() ?? composition.fps, 1)
    }

    var availableExportFPSOptions: [Double] {
        ExportFPSPolicy.availableOptions(maxSourceFPS: maximumSourceFPS)
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
    private let canvasPreferenceAspectKey = "canvasPreference.aspect"
    private let canvasPreferenceBackgroundKey = "canvasPreference.background"

    // MARK: - 编辑交互

    /// 拖拽开始时的元素位置锚点
    var dragAnchor: CGPoint?

    private let worksStore = WorksStore()
    private let folderStore = LibraryFolderStore()
    private let audioEngine = AudioPreviewEngine()
    private let workPersistence: WorkPersistenceCoordinator
    private var backgroundMediaReloadTask: Task<Void, Never>?
    private var cacheSizeTask: Task<Void, Never>?

    init() {
        workPersistence = WorkPersistenceCoordinator(store: worksStore)
        let persistence = workPersistence
        Task { [weak self] in
            let loaded = await persistence.load()
            guard let self, !Task.isCancelled else { return }
            self.works = loaded
            self.isLoadingWorks = false
        }
        // 恢复持久化的素材与文件夹
        FrameCache.shared.reload()
        clips = FrameCache.shared.allClips()
        // 背景目录扫描会读取视频轨道和动图帧信息，放到后台避免启动时阻塞主线程。
        Task { [weak self] in
            let media = await Task.detached(priority: .utility) {
                await BackgroundStore.shared.allUserMedia()
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

    private func markProjectClean(invalidateAutosave: Bool = true) {
        if invalidateAutosave {
            autosaveGeneration &+= 1
            autosaveTask?.cancel()
        } else {
            autosaveTask = nil
        }
        cleanCompositionSnapshot = composition
        hasUnsavedChanges = false
    }

    private func markProjectDirty() {
        hasUnsavedChanges = true
        scheduleDraftAutosave()
    }

    /// 在用户停止操作一小段时间后自动把当前工程保存为作品草稿。
    /// 统一放在 composition 的变更入口，覆盖时间轴、画布、检查器和工具面板。
    private func scheduleDraftAutosave() {
        autosaveGeneration &+= 1
        let generation = autosaveGeneration
        autosaveTask?.cancel()
        let snapshot = composition
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.autosaveGeneration == generation,
                  self.hasUnsavedChanges,
                  self.editingWorkID != nil,
                  self.composition == snapshot else { return }

            self.autosaveError = nil
            self.isAutosavingDraft = true
            let saved = await self.saveCurrentDraft(expectedComposition: snapshot)
            // 保存期间可能已经开始了新的编辑或新的保存任务；旧任务不能再修改状态，
            // 更不能把“快照已过期”误报成自动保存失败。
            guard self.autosaveGeneration == generation else { return }
            self.isAutosavingDraft = false
            guard !Task.isCancelled, self.composition == snapshot else { return }
            if !saved {
                self.autosaveError = "草稿自动保存失败，请稍后重试。"
            }
        }
    }

    /// 切换工程前取消旧工程的待保存任务，避免旧工程在新工程打开后写入。
    private func cancelDraftAutosave() {
        autosaveGeneration &+= 1
        autosaveTask?.cancel()
        autosaveTask = nil
        isAutosavingDraft = false
    }

    func dismissAutosaveError() {
        autosaveError = nil
    }

    func dismissSaveError() {
        saveError = nil
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
            FrameCache.shared.removeClipInBackground(id: clip.id)
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
        // 已保存作品只保存素材 ID；删除仍被作品引用的素材会让旧作品无法完整恢复。
        guard worksReferencingClip(clipID).isEmpty else { return }
        clips.removeAll { $0.id == clipID }
        FrameCache.shared.removeClipInBackground(id: clipID)
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

    /// 重命名素材；素材 ID 和帧文件保持不变，当前作品中的时间轴名称同步更新。
    func renameClip(_ clipID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let clipIndex = clips.firstIndex(where: { $0.id == clipID }),
              clips[clipIndex].name != trimmed else { return }

        clips[clipIndex].name = trimmed
        FrameCache.shared.registerInBackground(clips[clipIndex])

        guard var comp = composition else { return }
        var changed = false
        for index in comp.elements.indices {
            guard case .clip(let referencedID) = comp.elements[index].kind,
                  referencedID == clipID else { continue }
            if comp.elements[index].name != trimmed {
                comp.elements[index].name = trimmed
                changed = true
            }
        }
        if changed { composition = comp }
    }

    /// 返回仍引用指定素材的已保存作品，用于删除前的轻量保护提示。
    func worksReferencingClip(_ clipID: String) -> [WorkItem] {
        works.filter { work in
            work.composition.elements.contains { element in
                if case .clip(let referencedID) = element.kind {
                    return referencedID == clipID
                }
                return false
            }
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
        updateClip(clipID) { $0.edgeStyle = style }
    }

    /// 设置描边颜色（持久化到 clip.json）
    func setClipEdgeColor(_ clipID: String, _ hex: String) {
        updateClip(clipID) { $0.edgeColorHex = hex }
    }

    /// 设置描边粗细（持久化到 clip.json）
    func setClipEdgeThickness(_ clipID: String, _ thickness: EdgeThickness) {
        updateClip(clipID) { $0.edgeThickness = thickness }
    }

    /// 设置素材贴纸风格（持久化到 clip.json）
    func setClipStickerStyle(_ clipID: String, _ style: StickerStyle) {
        updateClip(clipID) { $0.stickerStyle = style }
    }

    /// 设置素材的排除帧（帧选择功能），持久化到 clip.json
    func setExcludedFrames(_ clipID: String, _ excluded: Set<Int>) {
        updateClip(clipID) { $0.excludedFrames = excluded }
    }

    /// 素材详情页每次顺时针旋转 90°，持久化到 clip.json。
    func rotateClip(_ clipID: String) {
        updateClip(clipID) {
            $0.rotationQuarterTurns = ($0.rotationQuarterTurns + 1) % 4
        }
    }

    /// 统一处理素材属性更新、清单持久化和画布刷新，避免多个设置入口行为不一致。
    private func updateClip(_ clipID: String, _ update: (inout SegmentedClip) -> Void) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        var clip = clips[index]
        update(&clip)
        clips[index] = clip
        FrameCache.shared.registerInBackground(clip)
        clipStyleVersion += 1
        markProjectDirty()
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
        rememberCanvasBackground(comp.background)
    }

    /// 设置为透明背景。编辑器使用棋盘格提示透明区域，导出时保留 alpha 通道。
    func setTransparentBackground() {
        guard var comp = composition ?? defaultComposition() else { return }
        comp.background = .clear
        composition = comp
        rememberCanvasBackground(comp.background)
    }

    /// 设置背景为预置图片
    func setBackground(preset fileName: String) {
        guard var comp = composition ?? defaultComposition() else { return }
        comp.background = BackgroundPreset(
            kind: .image, topColor: "FFFFFF", bottomColor: "FFFFFF", imageFileName: fileName
        )
        composition = comp
        rememberCanvasBackground(comp.background)
    }

    /// 设置背景为相册图片（写入 Backgrounds 目录后引用）
    func setBackground(imageData: Data) async {
        let fileName = await Task.detached(priority: .utility) {
            BackgroundStore.shared.saveUserImage(imageData)
        }.value
        guard let fileName else { return }
        guard var comp = composition ?? defaultComposition() else { return }
        comp.background = BackgroundPreset(
            kind: .image, topColor: "FFFFFF", bottomColor: "FFFFFF", imageFileName: fileName
        )
        composition = comp
        rememberCanvasBackground(comp.background)
    }

    /// 刷新背景媒体列表。素材选择器导入相册图片后调用。
    func reloadBackgroundMedia() {
        backgroundMediaReloadTask?.cancel()
        backgroundMediaReloadTask = Task { [weak self] in
            let media = await Task.detached(priority: .utility) {
                await BackgroundStore.shared.allUserMedia()
            }.value
            guard !Task.isCancelled else { return }
            self?.backgroundMedia = media
        }
    }

    /// 保存一张相册图片/动态图片，返回可用于创建元素的媒体 ID。
    @discardableResult
    func importBackgroundMedia(
        data: Data,
        preferredFileExtension: String? = nil,
        isVideo: Bool = false
    ) async -> String? {
        let id = await Task.detached(priority: .utility) {
            isVideo
                ? BackgroundStore.shared.saveUserVideo(data, preferredFileExtension: preferredFileExtension)
                : BackgroundStore.shared.saveUserImage(data, preferredFileExtension: preferredFileExtension)
        }.value
        guard let id else { return nil }
        return id
    }

    /// 添加一个背景图片元素。背景元素默认位于所有现有元素下方，并覆盖当前工程时长。
    func addBackgroundElement(mediaID: String) {
        guard let media = backgroundMedia.first(where: { $0.id == mediaID }),
              var comp = composition ?? defaultComposition() else { return }
        let settings = BackgroundElementSettings()
        let regionRect = backgroundRegionRect(settings.region, in: comp.canvasRect)
        // 动态背景的默认片段应当等于媒体自身完整播放时长，而不是已有工程时长。
        // 后续裁剪在时间轴调整，重复播放在检查器显式设置。
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
            sourceStartTime: 0,
            sourceEndTime: media.isAnimated ? max(media.duration, 0.1) : duration,
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

    /// 把全局画布边框样式同步为一个可排序的时间轴元素。样式仍保存在
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
        rememberCanvasBackground(comp.background)
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
        LogStore.log("library.clip.published id=\(clip.id) count=\(clips.count)")
        syncAudioPreview()
    }

    // MARK: - 新画布偏好

    /// 新工程使用的画布比例和背景。已有作品重新打开时仍以作品自身配置为准。
    private var preferredCanvasAspect: CanvasAspect {
        guard let raw = UserDefaults.standard.string(forKey: canvasPreferenceAspectKey),
              let aspect = CanvasAspect(rawValue: raw) else {
            return .landscape16x9
        }
        return aspect
    }

    private var preferredCanvasBackground: BackgroundPreset {
        guard let data = UserDefaults.standard.data(forKey: canvasPreferenceBackgroundKey),
              let background = try? JSONDecoder().decode(BackgroundPreset.self, from: data) else {
            return BackgroundPreset(kind: .solid, topColor: "FFFFFF", bottomColor: "FFFFFF")
        }
        return background
    }

    private func rememberCanvasAspect(_ aspect: CanvasAspect) {
        UserDefaults.standard.set(aspect.rawValue, forKey: canvasPreferenceAspectKey)
    }

    private func rememberCanvasBackground(_ background: BackgroundPreset) {
        guard let data = try? JSONEncoder().encode(background) else { return }
        UserDefaults.standard.set(data, forKey: canvasPreferenceBackgroundKey)
    }

    private func defaultComposition() -> Composition? {
        cancelDraftAutosave()
        pause()
        let aspect = preferredCanvasAspect
        let comp = Composition(
            name: NSLocalizedString("我的动态照片", comment: "Default composition name"),
            canvas: CanvasSpec(width: aspect.canvasSize.width, height: aspect.canvasSize.height),
            duration: 0,
            fps: 30,
            background: preferredCanvasBackground
        )
        editingWorkID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        composition = comp
        currentTime = 0
        markProjectClean()
        return comp
    }

    // MARK: - 画布比例

    /// 创建新画布工程；没有传入比例时使用用户上次选择的画布设置。
    func createComposition(aspect: CanvasAspect? = nil) {
        cancelDraftAutosave()
        pause()
        let selectedAspect = aspect ?? preferredCanvasAspect
        let size = selectedAspect.canvasSize
        let comp = Composition(
            name: NSLocalizedString("我的动态照片", comment: "Default composition name"),
            canvas: CanvasSpec(width: size.width, height: size.height),
            duration: 0,
            fps: 30,
            background: preferredCanvasBackground
        )
        editingWorkID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        composition = comp
        selectedElementIDs.removeAll()
        lastSelectedElementID = nil
        selectedAudioID = nil
        selectedBackground = true
        isCropping = false
        currentTime = 0
        syncAudioPreview()
        rememberCanvasAspect(selectedAspect)
        markProjectClean()
    }

    /// 确保有一个默认工程（直接添加素材/背景时调用）
    func ensureComposition() {
        if composition == nil {
            _ = defaultComposition()
        }
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
        rememberCanvasAspect(aspect)
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

    /// 时间轴、检查器共用动态源识别；不把单帧图片当成可裁剪的视频。
    func playbackSource(for element: CompositionElement) -> ElementPlaybackSource? {
        switch element.kind {
        case .clip(let id):
            guard let clip = FrameCache.shared.clip(id: id) ?? clips.first(where: { $0.id == id }),
                  clip.playbackFrameIndices.count > 1 else { return nil }
            return ElementPlaybackSource(duration: clip.playbackSourceDuration, playbackRate: clip.playbackSpeed)
        case .background(let id):
            guard let media = backgroundMedia.first(where: { $0.id == id }) ?? BackgroundStore.shared.media(named: id),
                  media.isAnimated else { return nil }
            return ElementPlaybackSource(duration: media.duration)
        case .decoration(let id), .effect(let id):
            guard let definition = DecorationRenderer.stickerDefinition(for: id),
                  definition.frameCount > 1 else { return nil }
            return ElementPlaybackSource(duration: definition.defaultDuration)
        case .text, .canvasEdge:
            return nil
        }
    }

    func setElementPlaybackCount(_ id: UUID, count: Int) {
        guard let element = composition?.elements.first(where: { $0.id == id }),
              let source = playbackSource(for: element) else { return }
        pause()
        let count = min(max(count, 1), 99)
        beginTimelineEdit()
        defer { finishTimelineEdit() }
        updateElement(id, { item in
            let range = source.range(for: item)
            item.sourceStartTime = range.start
            item.sourceEndTime = range.end
            // 检查器操作以源范围起点作为每轮循环的起点，清除时间轴拖拽留下的相位。
            item.sourcePlaybackOffset = nil
            item.playbackCount = count
            item.endTime = item.startTime + range.span / source.playbackRate * Double(count)
        }, recomputeDuration: false)
        recomputeDuration(autoFillOverlayElements: false)
    }

    /// 编辑重复所用的源片段，不移动工程入点；所有轮次使用同一份入点/出点。
    func setElementSourceRange(_ id: UUID, start: TimeInterval, end: TimeInterval) {
        guard let element = composition?.elements.first(where: { $0.id == id }),
              let source = playbackSource(for: element), start.isFinite, end.isFinite else { return }
        let minimumSpan = min(0.1 * source.playbackRate, source.duration)
        let start = min(max(start, 0), source.duration - minimumSpan)
        let end = min(max(end, start + minimumSpan), source.duration)
        let count = min(element.resolvedPlaybackCount(cycleDuration: source.cycleDuration(for: element)), 99)
        pause()
        beginTimelineEdit()
        defer { finishTimelineEdit() }
        updateElement(id, { item in
            item.sourceStartTime = start
            item.sourceEndTime = end
            // 检查器重新定义每一轮的源区间后，从该区间的起点重新开始播放。
            item.sourcePlaybackOffset = nil
            item.playbackCount = count
            item.endTime = item.startTime + (end - start) / source.playbackRate * Double(count)
        }, recomputeDuration: false)
        recomputeDuration(autoFillOverlayElements: false)
    }

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

        // 仅静态装饰/背景保留“默认铺满”行为，动态源的时长完全由裁剪与次数决定。
        // 先从内容最大时长中排除它，之后再让它跟随新的工程末端一起伸缩。
        if autoFillOverlayElements, previousDuration.isFinite, previousDuration > 0 {
            for index in comp.elements.indices {
                guard case .decoration = comp.elements[index].kind,
                      playbackSource(for: comp.elements[index]) == nil,
                      abs(comp.elements[index].endTime - previousDuration) <= 0.001 else { continue }
                autoFillStickerIndices.append(index)
            }
            for index in comp.elements.indices {
                guard case .background = comp.elements[index].kind,
                      playbackSource(for: comp.elements[index]) == nil,
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

        // 工程延长时只延长静态覆盖层，动态贴纸和背景绝不自动增加播放轮次。
        if autoFillOverlayElements, maxEnd > previousDuration + 0.001 {
            for index in comp.elements.indices {
                guard case .decoration = comp.elements[index].kind,
                      playbackSource(for: comp.elements[index]) == nil,
                      comp.elements[index].endTime <= previousDuration + 0.001 else { continue }
                comp.elements[index].endTime = maxEnd
            }
            for index in comp.elements.indices {
                guard case .background = comp.elements[index].kind,
                      playbackSource(for: comp.elements[index]) == nil,
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
        // “清空”同时结束当前作品的编辑会话，后续保存应创建新作品，不能覆盖旧作品。
        editingWorkID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        markProjectClean()
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
            endTime: max(comp.duration, 1),
            sourceStartTime: 0,
            sourceEndTime: max(comp.duration, 1)
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
        if clip.orientedWidth > 0, clip.orientedHeight > 0 {
            scale = min(
                0.8 * comp.canvas.width / CGFloat(clip.orientedWidth),
                0.8 * comp.canvas.height / CGFloat(clip.orientedHeight)
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
            sourceEndTime: clip.playbackSourceDuration
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
        let oldSpeed = max(clips[index].playbackSpeed, 0.01)
        clips[index].playbackSpeed = speed
        FrameCache.shared.registerInBackground(clips[index])
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
                    let count = comp.elements[i].resolvedPlaybackCount(
                        cycleDuration: max(sourceEnd - sourceStart, 0.001) / oldSpeed
                    )
                    comp.elements[i].sourceStartTime = sourceStart
                    comp.elements[i].sourceEndTime = sourceEnd
                    comp.elements[i].playbackCount = count
                    comp.elements[i].endTime = comp.elements[i].startTime
                        + max((sourceEnd - sourceStart) / max(speed, 0.01), 0.001) * Double(count)
                }
            }
            composition = comp
        }
        clipStyleVersion += 1
        markProjectDirty()
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
        // 播放是预览状态，隐藏编辑选框和检查器聚焦，避免选中框跟着画面闪动。
        clearElementSelection()
        selectedAudioID = nil
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
        let sourceDuration = DecorationRenderer.stickerDefinition(for: effectID)?.defaultDuration
        let element = CompositionElement(
            kind: .effect(effectID: effectID),
            name: effectID,
            transform: ElementTransform(
                position: CGPoint(x: comp.canvas.width / 2, y: comp.canvas.height / 2),
                scale: 1, rotation: 0
            ),
            zIndex: nextElementZIndex(in: comp),
            startTime: 0,
            endTime: sourceDuration ?? max(comp.duration, 1),
            sourceEndTime: sourceDuration ?? .greatestFiniteMagnitude
        )
        comp.elements.append(element)
        composition = comp
        selectElement(element.id)
        recomputeDuration()
    }

    /// 动态贴纸默认播放一次；循环必须通过检查器显式设置。
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
            endTime: stickerDuration,
            sourceStartTime: 0,
            sourceEndTime: stickerDuration
        )
        comp.elements.append(element)
        composition = comp
        selectElement(element.id)
        recomputeDuration()
    }

    // MARK: - 导出

    func export(
        format: ExportFormat,
        fps: Double,
        chatSticker: Bool = false,
        chatGIFPixelSize: CGFloat = 240,
        resolution: ExportResolution = .original
    ) async throws -> URL {
        guard let composition else { throw AppStateError.noComposition }
        isExporting = true
        exportProgress = 0
        exportNotice = nil
        RenderMemoryController.prepareForExport()
        defer {
            RenderMemoryController.finishExport()
            isExporting = false
        }
        let start = Date()
        let exportLogPrefix = format == .livePhoto ? "xdz.livephoto" : "export"
        LogStore.log("\(exportLogPrefix) start format=\(format.rawValue) fps=\(fps) duration=\(composition.duration)s elements=\(composition.elements.count) audioClips=\(composition.audioClips.count)")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(exportFileBaseName(composition.name))-\(UUID().uuidString).\(format.fileExtension)"
            )
        switch format {
        case .gif:
            if chatSticker {
                let result = try await GIFExporter().exportChatSticker(
                    composition,
                    to: url,
                    pixelSize: chatGIFPixelSize,
                    progress: { [weak self] value in
                        Task { @MainActor in self?.exportProgress = value }
                    }
                )
                if result.usedFrameSampling {
                    exportNotice = "为控制在 10 MB 内，已均匀抽帧至 \(Int(result.fps)) fps；画面尺寸仍为 \(result.pixelSize)×\(result.pixelSize)。"
                }
            } else {
                try await GIFExporter().export(
                    composition,
                    to: url,
                    fps: fps,
                    maxPixelSize: resolution.maxPixelSize
                ) { [weak self] value in
                    Task { @MainActor in self?.exportProgress = value }
                }
            }
        case .hevcAlpha, .h264:
            try await VideoExporter().export(
                composition,
                format: format,
                sourceResolver: { [weak self] sourceID in
                    self?.clips.first(where: { $0.id == sourceID })?.loadAudioURL()
                },
                to: url,
                fps: fps,
                maxPixelSize: resolution.maxPixelSize
            ) { [weak self] value in
                Task { @MainActor in self?.exportProgress = value }
            }
        case .livePhoto:
            LogStore.log(
                "xdz.livephoto export begin compositionSize=\(composition.renderRect.size.width)x\(composition.renderRect.size.height) "
                    + "fps=\(composition.fps) duration=\(composition.duration)s"
            )
            let output = try await LivePhotoExporter().export(composition, to: url) { [weak self] value in
                Task { @MainActor in self?.exportProgress = value }
            }
            let videoBytes = (try? FileManager.default.attributesOfItem(atPath: output.videoURL.path)[.size] as? Int) ?? 0
            LogStore.log(
                "xdz.livephoto export output video=\(output.videoURL.lastPathComponent) videoBytes=\(videoBytes) "
                    + "coverBytes=\(output.coverData.count) assetID=\(output.assetIdentifier)"
            )
            let authorized = await requestAddOnlyAuthorization()
            LogStore.log("xdz.livephoto photoLibrary authorized=\(authorized)")
            guard authorized else { throw AppStateError.photoLibraryDenied }
            let photosVideoURL = try makeLivePhotoPhotosCopy(from: output.videoURL)
            let photosCoverURL = try makeLivePhotoPhotosCoverCopy(
                from: output.coverData,
                assetIdentifier: output.assetIdentifier
            )
            defer {
                try? FileManager.default.removeItem(at: photosVideoURL)
                try? FileManager.default.removeItem(at: photosCoverURL)
            }
            try await saveLivePhoto(
                videoURL: photosVideoURL,
                coverURL: photosCoverURL,
                assetIdentifier: output.assetIdentifier
            )
            LogStore.log("xdz.livephoto photoLibrary save completed")
        }
        exportedURL = url
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log("\(exportLogPrefix) done elapsed=\(Int(Date().timeIntervalSince(start)))s size=\(size) bytes")
        savePosterForWidget()
        return url
    }

    private func exportFileBaseName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "LivingFrame" : cleaned
    }

    private func requestAddOnlyAuthorization() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        LogStore.log("xdz.livephoto photoLibrary authorization status=\(status.rawValue)")
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let requestedStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            LogStore.log("xdz.livephoto photoLibrary authorization requestedStatus=\(requestedStatus.rawValue)")
            return requestedStatus == .authorized
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func saveLivePhoto(videoURL: URL, coverURL: URL, assetIdentifier: String) async throws {
        let videoBytes = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
        let coverBytes = (try? FileManager.default.attributesOfItem(atPath: coverURL.path)[.size] as? Int) ?? 0
        LogStore.log(
            "xdz.livephoto save begin videoURL=\(videoURL.path) videoBytes=\(videoBytes) "
                + "coverURL=\(coverURL.path) coverBytes=\(coverBytes) assetID=\(assetIdentifier)"
        )
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.shouldMoveFile = true
                photoOptions.uniformTypeIdentifier = UTType.jpeg.identifier
                photoOptions.originalFilename = "LivePhoto-\(assetIdentifier).jpg"
                request.addResource(with: .photo, fileURL: coverURL, options: photoOptions)
                // Photos 接管独立副本；原始导出文件保留给导出页继续分享。
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = true
                videoOptions.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                videoOptions.originalFilename = "LivePhoto-\(assetIdentifier).mov"
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
            }
        } catch {
            let nsError = error as NSError
            LogStore.log(
                "xdz.livephoto save failed domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)"
            )
            throw error
        }
    }

    private func makeLivePhotoPhotosCopy(from sourceURL: URL) throws -> URL {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePhoto-Photos-\(UUID().uuidString).mov")
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int) ?? 0
        LogStore.log(
            "xdz.livephoto Photos copy created url=\(destinationURL.lastPathComponent) bytes=\(size) "
                + "source=\(sourceURL.lastPathComponent)"
        )
        return destinationURL
    }

    private func makeLivePhotoPhotosCoverCopy(from data: Data, assetIdentifier: String) throws -> URL {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePhoto-Photos-\(assetIdentifier).jpg")
        try data.write(to: destinationURL, options: .atomic)
        LogStore.log(
            "xdz.livephoto Photos cover created url=\(destinationURL.lastPathComponent) bytes=\(data.count)"
        )
        return destinationURL
    }

    // MARK: - 作品

    private func clipSettingsSnapshot(for comp: Composition) -> [WorkClipSettings] {
        let referencedClipIDs = Set(comp.elements.compactMap { element -> String? in
            guard case .clip(let clipID) = element.kind else { return nil }
            return clipID
        })
        return clips
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
    }

    /// 自动保存当前工程的草稿，不修改正式作品快照。
    /// 新工程尚未有作品 ID 时只保留在当前编辑会话中，点击“保存”后才创建正式作品。
    @discardableResult
    private func saveCurrentDraft(expectedComposition: Composition? = nil) async -> Bool {
        guard let comp = composition else { return false }
        guard expectedComposition == nil || expectedComposition == comp else { return false }
        guard let editingWorkID,
              let existing = works.first(where: { $0.id == editingWorkID }) else {
            // 未保存的新工程不能因为自动保存出现在作品列表中。
            return true
        }

        var work = existing
        work.draft = WorkDraft(
            updatedAt: Date(),
            composition: comp,
            clipSettings: clipSettingsSnapshot(for: comp)
        )
        let persistence = await workPersistence.saveAndLoad(work)
        guard persistence.0 else { return false }
        works = persistence.1
        LogStore.log("work.draft saved id=\(work.id)")
        return true
    }

    /// 立即写入当前草稿，用于用户离开当前作品前确保最近一次修改已落盘。
    @discardableResult
    func saveCurrentDraftNow() async -> Bool {
        cancelDraftAutosave()
        guard let snapshot = composition else { return false }
        let saved = await saveCurrentDraft(expectedComposition: snapshot)
        if !saved {
            autosaveError = "草稿保存失败，请稍后重试。"
        }
        return saved
    }

    /// 手动保存当前工程；这是唯一会更新正式作品快照的入口。
    @discardableResult
    func saveCurrentToWorks(expectedComposition: Composition? = nil) async -> Bool {
        guard !isSavingWork else { return false }
        guard let comp = composition else { return false }
        guard expectedComposition == nil || expectedComposition == comp else { return false }
        cancelDraftAutosave()
        isSavingWork = true
        saveError = nil
        defer { isSavingWork = false }
        let posterData = await Task.detached(priority: .utility) {
            guard let poster = CompositionRenderer(frameMaxPixelSize: 900).render(comp, at: 0) else {
                return Data?.none
            }
            return pngData(from: poster)
        }.value
        guard let posterData else {
            LogStore.log("work.save failed: poster render returned nil")
            saveError = "无法生成作品封面，请稍后重试。"
            return false
        }
        // 工程切换或继续编辑后，不要把已经过期的自动保存快照写入新工程。
        guard expectedComposition == nil || composition == comp else { return false }
        let existing = editingWorkID.flatMap { id in works.first { $0.id == id } }
        let now = Date()
        let clipSettings = clipSettingsSnapshot(for: comp)
        let work = WorkItem(
            id: existing?.id ?? UUID(),
            name: comp.name,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            composition: comp,
            clipSettings: clipSettings,
            posterData: posterData,
            format: existing?.format ?? defaultFormat,
            draft: nil
        )
        let persistence = await workPersistence.saveAndLoad(work)
        guard persistence.0 else {
            saveError = "作品保存失败，请稍后重试。"
            return false
        }
        editingWorkID = work.id
        works = persistence.1
        // 渲染封面期间用户可能继续编辑；只有保存的快照仍是当前工程时，
        // 才能把工程标记为干净，否则下一次自动保存需要继续追上最新修改。
        if composition == comp {
            // 当前保存任务本身正在执行，不要取消/作废它的 generation。
            markProjectClean(invalidateAutosave: false)
        } else {
            hasUnsavedChanges = true
            scheduleDraftAutosave()
        }
        LogStore.log("work.save done id=\(work.id) updated=\(existing != nil)")
        return true
    }

    /// 复制已保存作品，保留工程内容但使用新的作品和工程 ID。
    @discardableResult
    func duplicateWork(_ work: WorkItem) async -> Bool {
        var copy = work
        let now = Date()
        copy.id = UUID()
        copy.name = "\(work.name) 副本"
        copy.createdAt = now
        copy.updatedAt = now
        copy.composition.id = UUID()
        copy.composition.name = copy.name
        copy.draft = nil
        let saved = await workPersistence.save(copy, failureMessage: "work.duplicate failed")
        guard saved else { return false }
        works.insert(copy, at: 0)
        return true
    }

    /// 重命名作品；当前正在编辑的工程同步更新名称并沿用自动保存流程。
    func renameWork(_ work: WorkItem, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var renamed = work
        renamed.name = trimmed
        renamed.updatedAt = Date()
        let saved = await workPersistence.save(renamed, failureMessage: "work.rename failed")
        guard saved else { return }
        if let index = works.firstIndex(where: { $0.id == work.id }) {
            works[index] = renamed
        }
        if editingWorkID == work.id, var comp = composition {
            let wasDirty = hasUnsavedChanges
            comp.name = trimmed
            composition = comp
            if !wasDirty { markProjectClean() }
        }
    }

    /// 编辑器顶部的轻量重命名入口。名称变更沿用作品自动保存流程。
    func renameCurrentComposition(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var comp = composition, comp.name != trimmed else { return }
        comp.name = trimmed
        composition = comp
    }

    func deleteWork(_ work: WorkItem) {
        works.removeAll { $0.id == work.id }
        if editingWorkID == work.id { editingWorkID = nil }
        Task {
            await self.workPersistence.delete(work)
        }
    }

    func reopen(_ work: WorkItem, includingDraft: Bool = true) {
        cancelDraftAutosave()
        let draft = includingDraft ? work.draft : nil
        restoreClipSettings(draft?.clipSettings ?? work.clipSettings)
        var comp = draft?.composition ?? work.composition
        // 消毒工程中的非法变换值（NaN/Inf 会导致渲染失败）
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
            FrameCache.shared.registerInBackground(clip)
        }
        clipStyleVersion += 1
        markProjectClean()
        if draft != nil {
            // 正式作品仍是 clean snapshot；当前打开的是草稿，所以应显示未正式保存。
            hasUnsavedChanges = true
        }
    }

    /// 放弃当前作品草稿并恢复到最近一次正式保存的版本。
    func discardCurrentDraft() async {
        guard let editingWorkID,
              let work = works.first(where: { $0.id == editingWorkID }),
              work.draft != nil else { return }
        var clearedWork = work
        clearedWork.draft = nil
        let persistence = await workPersistence.saveAndLoad(clearedWork)
        guard persistence.0 else {
            saveError = "无法删除草稿，请稍后重试。"
            return
        }
        works = persistence.1
        reopen(clearedWork, includingDraft: false)
    }

    private func restoreClipSettings(_ settingsList: [WorkClipSettings]) {
        for settings in settingsList {
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
        Task.detached(priority: .utility) {
            if let items = try? FileManager.default.contentsOfDirectory(
                at: tmp, includingPropertiesForKeys: nil
            ) {
                for item in items where item.lastPathComponent.hasPrefix("LF-") {
                    try? FileManager.default.removeItem(at: item)
                }
            }
            LogStore.log("clearCache: 已清理临时文件，素材全部保留")
        }
    }

    /// 异步刷新素材占用，避免设置页 body 计算属性反复遍历素材目录。
    func refreshCacheSize() {
        cacheSizeTask?.cancel()
        cacheSizeText = "计算中…"
        cacheSizeTask = Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                FrameCache.shared.totalSizeBytes
            }.value
            guard !Task.isCancelled else { return }
            self?.cacheSizeText = ByteCountFormatter.string(
                fromByteCount: bytes,
                countStyle: .file
            )
        }
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
