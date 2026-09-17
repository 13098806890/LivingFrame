import AVFoundation
import AVKit
import LivingFrameCore
import PhotosUI
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isShowingExtractionPicker = false
    @State private var extractionPhotoSearchText = ""
    @State private var loadError: String?
    /// iCloud 素材下载进度（nil 表示进度未知）
    @State private var isDownloading = false
    @State private var downloadProgress: Double?
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    /// 当前拖拽悬停的目标文件夹（用于高亮）
    @State private var dragOverFolderID: String?
    /// 单击素材打开的详情页（nil = 不显示）
    @State private var menuClip: SegmentedClip?
    @State private var clipDeletionAlert: ClipDeletionAlert?
    /// 普通路径默认提取动态素材；静态首帧作为高级选项。
    @State private var defaultExtractKind: ExtractKind = .live
    /// 超过单个素材最长时长的视频，在动态提取前选择源视频范围。
    @State private var pendingVideoRange: PendingVideoRange?
    /// 当前批量提取的队列位置；提取仍串行执行以控制内存占用。
    @State private var extractionQueuePosition: Int?
    @State private var extractionQueueTotal = 0
    /// Retain the last imported sources so a failed extraction can be retried
    /// without asking the user to find the same media again.
    @State private var lastImportedSources: [ImportSource] = []
    @State private var lastImportedKinds: [ExtractKind] = []
    @State private var batchFailureMessageText: String?
    @State private var batchFailureTitle: String?
    @State private var importTask: Task<Void, Never>?
    @AccessibilityFocusState private var extractionEntryFocused: Bool
    @FocusState private var isExtractionSearchFocused: Bool

    private struct PendingVideoRange: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let duration: TimeInterval
        let maxDuration: TimeInterval
        var resume: (ClosedRange<TimeInterval>?) -> Void
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if isDownloading {
                        downloadCard
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if isExtractionActive {
                        segmentationCard
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    pickerSection
                    foldersSection
                    clipsSection
                }
                .padding(.horizontal)
                // Leave room for the system TabBar, including at XXXL text.
                .padding(.bottom, 24)
            }
            // The TabView bar stays visually overlaid on iPhone at XXXL. Keep
            // enough scrollable tail space for the last card/action to move
            // completely above it instead of relying on the device's inset.
            .safeAreaPadding(.bottom, 96)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .animation(.easeInOut(duration: 0.22), value: isDownloading)
            .animation(.easeInOut(duration: 0.22), value: isExtractionActive)
            .navigationTitle("素材库")
            .magicBackground()
            .alert("新建文件夹", isPresented: $showNewFolderAlert) {
                TextField("文件夹名称", text: $newFolderName)
                Button("创建") {
                    appState.createFolder(named: newFolderName)
                    newFolderName = ""
                }
                Button("取消", role: .cancel) {
                    newFolderName = ""
                }
            } message: {
                Text("整理剪影素材")
            }
            .alert(
                NSLocalizedString(
                    batchFailureTitle ?? (loadError != nil ? "导入失败" : "剪影生成失败"),
                    comment: "Import alert title"
                ),
                isPresented: Binding(
                    get: { loadErrorMessage != nil },
                    set: { if !$0 { loadError = nil; appState.segmentationError = nil } }
                )
            ) {
                if !lastImportedSources.isEmpty || isMixedBatchRetryFixture {
                    Button(NSLocalizedString("重试", comment: "Retry extraction")) {
                        retryLastExtraction()
                    }
                }
                Button(NSLocalizedString("选择其他素材", comment: "Choose different media")) {
                    chooseDifferentMedia()
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                    clearExtractionError()
                }
            } message: {
                Text(loadErrorMessage ?? "")
            }
            .sheet(item: $pendingVideoRange, onDismiss: {
                pendingVideoRange?.resume(nil)
                pendingVideoRange = nil
            }) { request in
                VideoRangePickerView(
                    url: request.url,
                    name: request.name,
                    duration: request.duration,
                    maxDuration: request.maxDuration,
                    onCancel: {
                        request.resume(nil)
                        pendingVideoRange = nil
                    },
                    onConfirm: { range in
                        request.resume(range)
                        pendingVideoRange = nil
                    }
                )
            }
            .fullScreenCover(item: $menuClip) { clip in
                ClipMenuView(
                    clip: clip,
                    onClose: { menuClip = nil }
                )
                .environmentObject(appState)
            }
            .onAppear {
#if DEBUG
                // Deterministic UI-only fixture for the import failure alert;
                // production builds never inject this state.
                if ProcessInfo.processInfo.arguments.contains("-UIAuditInjectImportFailure") {
                    loadError = NSLocalizedString("无法读取所选素材", comment: "Load failure detail")
                }
                if ProcessInfo.processInfo.arguments.contains("-UIAuditInjectAllImportFailure") {
                    batchFailureTitle = "导入失败"
                    batchFailureMessageText = batchFailureMessage(
                        successCount: 0,
                        importFailureCount: 2,
                        extractionFailureCount: 0
                    )
                }
                if ProcessInfo.processInfo.arguments.contains("-UIAuditInjectSegmentationFailure") {
                    batchFailureTitle = "剪影生成失败"
                    batchFailureMessageText = NSLocalizedString(
                        "当前设备暂时无法完成人物识别。请稍后重试，或换一张照片/视频。",
                        comment: "Person segmentation failure fixture"
                    )
                }
                if isMixedBatchRetryFixture {
                    batchFailureTitle = "剪影生成失败"
                    batchFailureMessageText = "部分素材未完成：成功 1 项，1 项失败。请重试或选择其他素材。"
                }
#endif
            }
            .onDisappear {
                importTask?.cancel()
            }
        }
    }

    // MARK: - 素材入口

    private var pickerSection: some View {
        VStack(spacing: 8) {
            if #available(iOS 27.0, *) {
                extractionPhotoSearchField
            }
            extractionPickerControl

            Menu {
                Section("提取方式") {
                    Button {
                        defaultExtractKind = .live
                    } label: {
                        Label("动态剪影（默认）", systemImage: defaultExtractKind == .live ? "checkmark" : "sparkles")
                    }
                    .accessibilityIdentifier("library-extraction-kind-live")
                    Button {
                        defaultExtractKind = .static
                    } label: {
                        Label("静态剪影（只取首帧）", systemImage: defaultExtractKind == .static ? "checkmark" : "photo")
                    }
                    .accessibilityIdentifier("library-extraction-kind-static")
                }

                Section("提取帧率") {
                    ForEach(AppState.processingFPSOptions, id: \.self) { option in
                        Button {
                            appState.processingFPS = option
                        } label: {
                            Label(
                                "\(fpsTitle(option)) fps",
                                systemImage: abs(appState.processingFPS - option) < 0.01 ? "checkmark" : "circle"
                            )
                        }
                        .accessibilityIdentifier("library-extraction-fps-\(fpsTitle(option))")
                    }
                }
            } label: {
                Label(
                    extractionSettingsLabel,
                    systemImage: "slider.horizontal.3"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(LF.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("剪影生成设置")
            .accessibilityIdentifier("library-extraction-settings")
        }
        .onChange(of: isShowingExtractionPicker) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            Task { @MainActor in
                // PhotosPicker updates its selection as it dismisses. Read it on
                // the next main-actor turn so all selected assets are included.
                await Task.yield()
                handleExtractionSelection(pickerItems)
            }
        }
    }

    @ViewBuilder
    private var extractionPickerControl: some View {
        let button = Button {
            isExtractionSearchFocused = false
            isShowingExtractionPicker = true
        } label: {
            SectionCard(title: nil) {
                VStack(spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 34))
                            .foregroundStyle(LF.gold)

                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(LF.gold, in: Circle())
                            .overlay {
                                Circle().stroke(LF.surface, lineWidth: 1.5)
                            }
                            .offset(x: 5, y: -4)
                    }
                    .frame(width: 40, height: 40)

                    Text("选择视频 / Live Photo / 照片")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("自动识别人物，生成透明剪影素材，全程在设备端处理")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .photosPicker(
            isPresented: $isShowingExtractionPicker,
            selection: $pickerItems,
            maxSelectionCount: 5,
            selectionBehavior: .ordered,
            matching: .any(of: [.videos, .livePhotos, .images])
        )
        .disabled(isDownloading || isExtractionActive)
        .accessibilityIdentifier("library-extraction-entry")
        .accessibilityLabel("添加素材")
        .accessibilityHint("选择视频 / Live Photo / 照片")
        .accessibilityFocused($extractionEntryFocused)

        if #available(iOS 27.0, *) {
            button.photosPickerSearchText(normalizedExtractionPhotoSearchText)
        } else {
            button
        }
    }

    @available(iOS 27.0, *)
    private var extractionPhotoSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LF.textSecondary)

            TextField("搜索照片：猫、狗或地点", text: $extractionPhotoSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isExtractionSearchFocused)
                .onSubmit {
                    isExtractionSearchFocused = false
                    guard !isDownloading, !isExtractionActive else { return }
                    isShowingExtractionPicker = true
                }
                .accessibilityIdentifier("library-extraction-photo-search")

            if !extractionPhotoSearchText.isEmpty {
                Button {
                    extractionPhotoSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LF.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(
            LF.surface2.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LF.brandTint.opacity(0.18), lineWidth: 1)
        }
    }

    @available(iOS 27.0, *)
    private var normalizedExtractionPhotoSearchText: String? {
        let text = extractionPhotoSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func handleExtractionSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        // Clear only after the picker has closed; clearing its live selection
        // while it is open dismisses it after the first tap.
        pickerItems.removeAll()
        // A new selection starts a new retry batch. Never let an older
        // failed URL remain eligible for a later retry action.
        lastImportedSources.removeAll()
        lastImportedKinds.removeAll()
        clearExtractionError()
        isDownloading = true
        downloadProgress = nil
        importTask = Task { @MainActor in
            // 1. 并行下载所有选中素材（iCloud 下载可多线程加速）
            var downloadedSources: [(index: Int, source: ImportSource)] = []
            var importFailures: [String] = []
            await withTaskGroup(of: (Int, ImportLoadResult).self) { group in
                for (index, item) in items.enumerated() {
                    group.addTask { (index, await load(item)) }
                }
                for await result in group {
                    switch result.1 {
                    case .success(let source):
                        downloadedSources.append((result.0, source))
                    case .failure(let message):
                        importFailures.append(message)
                    }
                }
            }
            // 下载完成即隐藏下载进度条（剪影生成阶段由进度卡片展示）
            isDownloading = false
            let sources = downloadedSources
                .sorted { $0.index < $1.index }
                .map(\.source)
            guard !Task.isCancelled else { return }
            guard !sources.isEmpty else {
                batchFailureTitle = "导入失败"
                batchFailureMessageText = batchFailureMessage(
                    successCount: 0,
                    importFailureCount: importFailures.count,
                    extractionFailureCount: 0
                )
                return
            }

            // 2. 视频默认直接按动态素材提取；需要静态首帧时再从高级选项进入。
            let kinds = sources.map { isVideoSource($0) ? defaultExtractKind : .static }
            startExtraction(
                sources: sources,
                kinds: kinds,
                importFailures: importFailures,
                importFailureCount: importFailures.count
            )
        }
    }

    private func fpsTitle(_ fps: Double) -> String {
        if abs(fps.rounded() - fps) < 0.01 { return String(Int(fps.rounded())) }
        return String(format: "%.1f", fps)
    }

    private var extractionSettingsLabel: String {
        let kind = defaultExtractKind == .live
            ? NSLocalizedString("动态剪影", comment: "Animated cutout asset")
            : NSLocalizedString("静态剪影", comment: "Still cutout asset")
        return String(
            format: NSLocalizedString("剪影素材 · %@ · %@ fps", comment: "Cutout asset extraction summary"),
            kind,
            fpsTitle(appState.processingFPS)
        )
    }

    private enum ExtractKind: Hashable {
        case live
        case `static`
    }

    private func isVideoSource(_ source: ImportSource) -> Bool {
        if case .video = source { return true }
        return false
    }

    /// 按选择的方式串行提取，保留原有的方向、首帧和长视频范围逻辑。
    private func startExtraction(
        sources: [ImportSource],
        kinds: [ExtractKind],
        importFailures: [String] = [],
        importFailureCount: Int = 0
    ) {
        importTask?.cancel()
        extractionQueueTotal = sources.count
        extractionQueuePosition = nil
        importTask = Task { @MainActor in
            var lastExtractedClip: SegmentedClip?
            var extractedCount = 0
            var extractionFailures = importFailures
            var failedSources: [ImportSource] = []
            var failedKinds: [ExtractKind] = []
            for (index, pair) in zip(sources.indices, zip(sources, kinds)) {
                guard !Task.isCancelled else { break }
                extractionQueuePosition = index + 1
                let source = pair.0
                let kind = pair.1
                switch source {
                case .video(let url, let name, let stillOrientation, let stillURL):
                    switch kind {
                    case .live:
                        let duration = await videoDuration(of: url)
                        if duration > appState.maxExtractionDuration {
                            let range: ClosedRange<TimeInterval>? = await withCheckedContinuation { continuation in
                                pendingVideoRange = PendingVideoRange(
                                    url: url,
                                    name: name,
                                    duration: duration,
                                    maxDuration: appState.maxExtractionDuration
                                ) { selectedRange in
                                    continuation.resume(returning: selectedRange)
                                }
                            }
                            guard let range else { continue }
                            let extractedClip = await appState.startSegmenting(
                                url: url,
                                name: name,
                                sourceStartTime: range.lowerBound,
                                sourceEndTime: range.upperBound,
                                stillOrientation: stillOrientation
                            )
                            if let extractedClip {
                                extractedCount += 1
                                lastExtractedClip = extractedClip
                            } else {
                                extractionFailures.append(appState.segmentationError ?? "video extraction failed")
                                failedSources.append(source)
                                failedKinds.append(kind)
                            }
                        } else {
                            let extractedClip = await appState.startSegmenting(
                                url: url,
                                name: name,
                                stillOrientation: stillOrientation
                            )
                            if let extractedClip {
                                extractedCount += 1
                                lastExtractedClip = extractedClip
                            } else {
                                extractionFailures.append(appState.segmentationError ?? "video extraction failed")
                                failedSources.append(source)
                                failedKinds.append(kind)
                            }
                        }
                    case .static:
                        if let cgImage = await firstFrame(of: url, stillURL: stillURL) {
                            let extractedClip = await appState.startPhotoSegmenting(cgImage: cgImage, name: name)
                            if let extractedClip {
                                extractedCount += 1
                                lastExtractedClip = extractedClip
                            } else {
                                extractionFailures.append(appState.segmentationError ?? "photo extraction failed")
                                failedSources.append(source)
                                failedKinds.append(kind)
                            }
                        } else {
                            extractionFailures.append("source frame unavailable")
                            failedSources.append(source)
                            failedKinds.append(kind)
                        }
                    }
                case .photo(let cgImage, let name):
                    let extractedClip = await appState.startPhotoSegmenting(cgImage: cgImage, name: name)
                    if let extractedClip {
                        extractedCount += 1
                        lastExtractedClip = extractedClip
                    } else {
                        extractionFailures.append(appState.segmentationError ?? "photo extraction failed")
                        failedSources.append(source)
                        failedKinds.append(kind)
                    }
                }
            }
            extractionQueuePosition = nil
            extractionQueueTotal = 0
            // Only failed sources remain retryable. Successful sources must
            // never be sent through AppState again, otherwise addClip would
            // create duplicates after a mixed batch failure.
            if !Task.isCancelled {
                lastImportedSources = failedSources
                lastImportedKinds = failedKinds
            }
            if !Task.isCancelled, let lastExtractedClip {
                menuClip = lastExtractedClip
            }
            if !Task.isCancelled, !extractionFailures.isEmpty {
                let extractionFailureCount = max(extractionFailures.count - importFailureCount, 0)
                batchFailureTitle = extractionFailureCount > 0 ? "剪影生成失败" : "导入失败"
                batchFailureMessageText = batchFailureMessage(
                    successCount: extractedCount,
                    importFailureCount: importFailureCount,
                    extractionFailureCount: extractionFailureCount
                )
            }
        }
    }

    private func videoDuration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    private var loadErrorMessage: String? {
        if let batchFailureMessageText { return batchFailureMessageText }
        guard let rawError = loadError ?? appState.segmentationError else { return nil }
        return userFacingExtractionError(for: rawError)
    }

    /// Translate implementation errors at the UI boundary. AppState keeps the
    /// original error in LogStore so diagnostics do not lose the Vision or
    /// AVFoundation details.
    private func userFacingExtractionError(for rawError: String) -> String {
        let normalized = rawError.lowercased()
        if normalized.contains("inference") || normalized.contains("vision") || normalized.contains("model") {
            return NSLocalizedString(
                "当前设备暂时无法完成人物识别。请稍后重试，或换一张照片/视频。",
                comment: "Model or Vision unavailable extraction failure"
            )
        }
        if normalized.contains("unsupported") || normalized.contains("format") {
            return NSLocalizedString(
                "这个素材格式暂不支持。请换一张照片或一段视频重试。",
                comment: "Unsupported media extraction failure"
            )
        }
        if normalized.contains("read") || normalized.contains("load") || normalized.contains("data")
            || normalized.contains("无法读取") || normalized.contains("读取") {
            return NSLocalizedString(
                "无法读取这个素材。请确认素材仍在相册中，或选择其他素材。",
                comment: "Media read extraction failure"
            )
        }
        return NSLocalizedString(
            "素材处理没有完成。请重试，或选择其他照片/视频。",
            comment: "Generic extraction failure"
        )
    }

    private func batchFailureMessage(
        successCount: Int,
        importFailureCount: Int,
        extractionFailureCount: Int
    ) -> String {
        if extractionFailureCount == 0, successCount == 0 {
            return String(
                format: NSLocalizedString(
                    "素材导入失败：%d 项素材无法读取。请重新选择素材。",
                    comment: "All media import failed"
                ),
                importFailureCount
            )
        }
        if successCount > 0 {
            return String(
                format: NSLocalizedString(
                    "部分素材未完成：成功 %d 项，%d 项失败。请重试或选择其他素材。",
                    comment: "Mixed extraction batch failure"
                ),
                successCount,
                importFailureCount + extractionFailureCount
            )
        }
        return NSLocalizedString(
            "当前设备暂时无法完成人物识别。请稍后重试，或换一张照片/视频。",
            comment: "All person segmentation failed"
        )
    }

    private func clearExtractionError() {
        loadError = nil
        appState.segmentationError = nil
        batchFailureMessageText = nil
        batchFailureTitle = nil
    }

    private func retryLastExtraction() {
#if DEBUG
        if isMixedBatchRetryFixture {
            clearExtractionError()
            batchFailureTitle = "剪影生成失败"
            batchFailureMessageText = "重试完成：成功素材仍为 1 项；没有重复添加。"
            return
        }
#endif
        guard !lastImportedSources.isEmpty else {
            chooseDifferentMedia()
            return
        }
        clearExtractionError()
        startExtraction(sources: lastImportedSources, kinds: lastImportedKinds)
    }

    private func chooseDifferentMedia() {
        clearExtractionError()
        pickerItems.removeAll()
        lastImportedSources.removeAll()
        lastImportedKinds.removeAll()
        // PhotosPicker cannot be opened programmatically from an alert. Move
        // accessibility focus back to the actual entry so the next action is
        // explicit and never retries the old source.
        DispatchQueue.main.async {
            extractionEntryFocused = true
        }
    }

    private var isMixedBatchRetryFixture: Bool {
#if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-UIAuditInjectMixedBatchRetry")
#else
        return false
#endif
    }

    /// 下载完成的待生成剪影素材（下载与处理分离：下载并行，剪影生成串行）
    /// stillURL：Live Photo 的配套静态图（可选，非 Live 为 nil）
    private enum ImportSource {
        case video(url: URL, name: String, stillOrientation: CGImagePropertyOrientation, stillURL: URL?)
        case photo(cgImage: CGImage, name: String)
    }

    private enum ImportLoadResult {
        case success(ImportSource)
        case failure(String)
    }

    private func load(_ item: PhotosPickerItem) async -> ImportLoadResult {
        let types = item.supportedContentTypes
        LogStore.log("load: itemIdentifier=\(item.itemIdentifier ?? "nil") types=\(types.map(\.identifier))")
        // 1. Live Photo：PHAsset 视频轨优先，PHLivePhoto 传输兜底
        //    （iCloud 未下载的 Live Photo 常不报 live-photo 类型、itemIdentifier 为 nil）
        if let source = await loadLivePhoto(item: item) { return .success(source) }
        // 2. 视频
        if types.contains(where: { $0.conforms(to: .movie) }),
           let source = await loadMovie(item: item) { return .success(source) }
        // 3. 普通照片：生成单帧剪影
        if types.contains(where: { $0.conforms(to: .image) }),
           let source = await loadPhoto(item: item) { return .success(source) }
        let message = NSLocalizedString("无法读取所选素材", comment: "Load failure detail")
        LogStore.log("load failed: \(message) itemIdentifier=\(item.itemIdentifier ?? "nil")")
        return .failure(message)
    }

    private func loadLivePhoto(item: PhotosPickerItem) async -> ImportSource? {
        let progressHandler: @Sendable (Double) -> Void = { value in
            Task { @MainActor in self.downloadProgress = value }
        }
        guard let video = await PhotoLibraryMediaImporter.loadExtractionVideo(
            from: item,
            progress: progressHandler
        ) else { return nil }
        return .video(
            url: video.url,
            name: video.name,
            stillOrientation: video.stillOrientation,
            stillURL: video.stillURL
        )
    }

    private func loadMovie(item: PhotosPickerItem) async -> ImportSource? {
        guard let movie = try? await item.loadTransferable(type: MovieFile.self) else {
            LogStore.log("loadMovie: MovieFile load failed")
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: movie.url.path)[.size] as? Int) ?? 0
        LogStore.log("loadMovie: URL=\(movie.url.path) size=\(size) bytes")
        return .video(url: movie.url, name: movie.url.lastPathComponent, stillOrientation: .up, stillURL: nil)
    }

    private func loadPhoto(item: PhotosPickerItem) async -> ImportSource? {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            LogStore.log("loadPhoto: Data load failed")
            return nil
        }
        guard let image = UIImage(data: data),
              let fixed = image.fixedOrientation() else {
            LogStore.log("loadPhoto: UIImage decode failed data=\(data.count) bytes")
            return nil
        }
        LogStore.log("loadPhoto: data=\(data.count) bytes size=\(image.size.width)x\(image.size.height) orientation=\(image.imageOrientation.rawValue)")
        return .photo(
            cgImage: fixed,
            name: NSLocalizedString("照片", comment: "Photo clip name")
        )
    }

    private func copyToTemporaryFile(_ url: URL) async throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-import-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// 静态贴纸源图：Live Photo 用配套静态图，普通视频取首帧
    private func firstFrame(of videoURL: URL, stillURL: URL?) async -> CGImage? {
        if let stillURL {
            // 用 fixedOrientation() 应用 EXIF 朝向，避免竖拍照片被旋转
            guard let fixed = UIImage(contentsOfFile: stillURL.path)?.fixedOrientation() else {
                LogStore.log("firstFrame: still image decode failed")
                return nil
            }
            return fixed
        }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let (image, _) = try await generator.image(at: .zero)
            LogStore.log("firstFrame: video first frame \(image.width)x\(image.height)")
            return image
        } catch {
            LogStore.log("firstFrame: video first frame failed error=\(error)")
            return nil
        }
    }

    // MARK: - 文件夹

    /// 文件夹栏：新建入口和已有文件夹共享同一个横向滚动区域。
    private var foldersSection: some View {
        SectionCard(title: nil) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button {
                        showNewFolderAlert = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(LF.surface2.opacity(0.5), in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(LF.surface2, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                            .foregroundStyle(LF.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新建文件夹")
                    .accessibilityIdentifier("library-new-folder")

                    if appState.rootFolders().isEmpty {
                        Text(NSLocalizedString("还没有文件夹", comment: "No folders"))
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                    } else {
                        ForEach(appState.rootFolders()) { folder in
                            NavigationLink {
                                FolderDetailView(folder: folder)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder.fill")
                                        .font(.title2)
                                        .foregroundStyle(LF.folderIcon)
                                    Text(folder.name)
                                        .lineLimit(1)
                                    Text("\(folder.clipIDs.count)")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(dragOverFolderID == folder.id ? LF.folderIcon : LF.textSecondary)
                                    if appState.hasChildFolders(folder.id) {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(dragOverFolderID == folder.id ? LF.folderIcon : LF.textSecondary)
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(minHeight: 44)
                                .contentShape(Capsule())
                                .background(
                                    dragOverFolderID == folder.id ? LF.selectionFill : LF.surface2,
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(
                                            dragOverFolderID == folder.id ? LF.brandTint : .clear,
                                            lineWidth: 2
                                        )
                                }
                                .foregroundStyle(LF.textPrimary)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    appState.deleteFolder(folder)
                                } label: {
                                    Label(NSLocalizedString("删除文件夹", comment: "Delete folder"), systemImage: "trash")
                                }
                            }
                            // 拖拽素材到此文件夹
                            .dropDestination(for: String.self) { clipIDs, _ in
                                for clipID in clipIDs {
                                    appState.moveClip(clipID, toFolder: folder.id)
                                }
                                dragOverFolderID = nil
                                return true
                            } isTargeted: { targeted in
                                dragOverFolderID = targeted ? folder.id : nil
                            }
                        }
                    }
                }
            }
            .frame(height: 46)
            .accessibilityIdentifier("library-folders-scroll")
        }
    }

    // MARK: - 下载 / 保存进度

    private var downloadCard: some View {
        SectionCard(title: "正在下载") {
            HStack {
                if let downloadProgress {
                    ProgressView(value: downloadProgress)
                        .tint(LF.gold)
                    Text(String(format: "%d%%", Int(downloadProgress * 100)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                } else {
                    ProgressView()
                        .tint(LF.gold)
                    Text("从 iCloud 下载中…")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
            }
        }
    }

    // MARK: - 剪影生成进度

    private var isExtractionActive: Bool {
        appState.isSegmenting || extractionQueuePosition != nil
    }

    private var segmentationCard: some View {
        SectionCard(title: "正在生成剪影") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if appState.isSegmenting {
                        ProgressView(value: appState.segmentationProgress)
                            .tint(LF.gold)
                    } else {
                        ProgressView()
                            .tint(LF.gold)
                    }
                    Text(appState.isSegmenting
                         ? String(format: "%d%%", Int(appState.segmentationProgress * 100))
                         : NSLocalizedString("准备中…", comment: "Preparing extraction"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                }
                if let extractionQueuePosition {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("第 %1$lld/%2$lld 个素材", comment: "Extraction queue position"),
                        Int64(extractionQueuePosition), Int64(extractionQueueTotal)
                    ))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LF.header)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(appState.segmentingName.isEmpty ? "正在准备剪影素材" : appState.segmentingName)
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("本次最多处理 %1$lld 秒，超出部分从开头截取", comment: "Maximum extraction duration"),
                    Int64(appState.maxExtractionDuration)
                ))
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("取消生成", role: .cancel) {
                    importTask?.cancel()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("library-extraction-progress-cancel")
            }
        }
        .accessibilityIdentifier("library-extraction-progress")
    }

    // MARK: - 素材网格

    private var clipsSection: some View {
        SectionCard(verbatimTitle: NSLocalizedString("全部素材", comment: "All clips")) {
            if appState.clips.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "还没有素材",
                    message: "选择视频、Live Photo 或照片，\n自动生成透明剪影素材"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(appState.clips) { clip in
                        // 四个角标统一由 ClipCell 锚定在预览缩略图内。
                        ClipCell(
                            clip: clip,
                            onOpen: { menuClip = clip },
                            onDelete: { requestClipDeletion(clip) },
                            deleteAccessibilityLabel: "删除素材",
                            deleteAccessibilityIdentifier: "library-delete-clip-\(clip.id)"
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-extraction-clips-section")
        .alert(item: $clipDeletionAlert) { request in
            switch request.kind {
            case .confirm:
                return Alert(
                    title: Text("删除素材？"),
                    message: Text("删除后无法恢复。"),
                    primaryButton: .destructive(Text("删除")) {
                        appState.deleteClip(request.clip.id)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .referenced:
                return Alert(
                    title: Text("素材正在使用中"),
                    message: Text(String.localizedStringWithFormat(
                        NSLocalizedString("请先从以下作品中移除它，再删除素材：\n%1$@", comment: "Asset is used by these works"),
                        request.referencedWorkNames.joined(separator: "、") as NSString
                    )),
                    dismissButton: .cancel(Text("知道了"))
                )
            }
        }
    }

    private func requestClipDeletion(_ clip: SegmentedClip) {
        let workNames = appState.worksReferencingClip(clip.id).map(\.name)
        clipDeletionAlert = ClipDeletionAlert(
            clip: clip,
            kind: workNames.isEmpty ? .confirm : .referenced,
            referencedWorkNames: workNames
        )
    }
}

private struct ClipDeletionAlert: Identifiable {
    enum Kind {
        case confirm
        case referenced
    }

    let clip: SegmentedClip
    let kind: Kind
    let referencedWorkNames: [String]

    var id: String {
        switch kind {
        case .confirm: "\(clip.id)-confirm-delete"
        case .referenced: "\(clip.id)-delete-blocked"
        }
    }
}

private struct VideoRangePickerView: View {
    let url: URL
    let name: String
    let duration: TimeInterval
    let maxDuration: TimeInterval
    let onCancel: () -> Void
    let onConfirm: (ClosedRange<TimeInterval>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startTime: TimeInterval
    @State private var endTime: TimeInterval
    @State private var selectedDetent: PresentationDetent = .large
    @State private var videoAspectRatio: CGFloat = 16.0 / 9.0
    @StateObject private var previewController: VideoRangePreviewController

    init(
        url: URL,
        name: String,
        duration: TimeInterval,
        maxDuration: TimeInterval,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ClosedRange<TimeInterval>) -> Void
    ) {
        let safeDuration = max(duration, 0.1)
        let safeMaxDuration = max(maxDuration, 0.1)
        self.url = url
        self.name = name
        self.duration = safeDuration
        self.maxDuration = safeMaxDuration
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _startTime = State(initialValue: 0)
        _endTime = State(initialValue: min(safeDuration, safeMaxDuration))
        _previewController = StateObject(wrappedValue: VideoRangePreviewController(url: url))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择要提取的视频片段")
                            .font(.headline)
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                            .lineLimit(1)
                    }

                    ZStack(alignment: .topLeading) {
                        VideoPlayer(player: previewController.player)
                            .aspectRatio(videoAspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .background(.black)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Label("预览选中片段", systemImage: "play.rectangle.fill")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.58), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }

                    VideoRangeTimeline(
                        url: url,
                        duration: duration,
                        startTime: $startTime,
                        endTime: $endTime,
                        maxDuration: maxDuration
                    )

                    HStack(spacing: 10) {
                        Label(
                            String.localizedStringWithFormat(
                                NSLocalizedString("已选 %1$@", comment: "Selected video duration"),
                                formatTimestamp(endTime - startTime) as NSString
                            ),
                            systemImage: "scissors"
                        )
                        Spacer(minLength: 8)
                        Text("\(formatTimestamp(startTime)) – \(formatTimestamp(endTime))")
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LF.textSecondary)

                    Button {
                        if previewController.isPlaying {
                            previewController.stop()
                        } else {
                            previewController.preview(start: startTime, end: endTime)
                        }
                    } label: {
                        Label(
                            previewController.isPlaying ? "停止预览" : "预览选中片段",
                            systemImage: previewController.isPlaying ? "stop.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LF.header)
                }
                .padding(20)
            }
            .lfNavigationTitle("视频范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成剪影") {
                        onConfirm(startTime...endTime)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .magicBackground()
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(LF.background.opacity(0.94), for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .onChange(of: startTime) { _, _ in
            if previewController.isPlaying { previewController.stop() }
        }
        .onChange(of: endTime) { _, _ in
            if previewController.isPlaying { previewController.stop() }
        }
        .onDisappear {
            previewController.stop()
        }
        .task(id: url) {
            await loadVideoAspectRatio()
        }
    }

    private func formatTimestamp(_ value: TimeInterval) -> String {
        let safeValue = max(value, 0)
        return String(format: "%d:%04.1f", Int(safeValue) / 60, safeValue.truncatingRemainder(dividingBy: 60))
    }

    private func loadVideoAspectRatio() async {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let naturalSize = try? await track.load(.naturalSize),
              let preferredTransform = try? await track.load(.preferredTransform) else {
            return
        }
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = abs(transformedSize.width)
        let height = abs(transformedSize.height)
        guard width > 0, height > 0, !Task.isCancelled else { return }
        videoAspectRatio = width / height
    }
}

@MainActor
private final class VideoRangePreviewController: ObservableObject {
    let player: AVPlayer
    @Published private(set) var isPlaying = false
    private var boundaryObserver: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
    }

    func preview(start: TimeInterval, end: TimeInterval) {
        removeBoundaryObserver()
        let startTime = CMTime(seconds: max(start, 0), preferredTimescale: 600)
        let endTime = CMTime(seconds: max(end, start + 0.1), preferredTimescale: 600)
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.pause()
                self.player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                self.isPlaying = false
            }
        }
        isPlaying = true
        player.play()
    }

    func stop() {
        player.pause()
        removeBoundaryObserver()
        isPlaying = false
    }

    private func removeBoundaryObserver() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
    }

    deinit {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
        }
    }
}

private struct VideoRangeTimeline: View {
    let url: URL
    let duration: TimeInterval
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval
    let maxDuration: TimeInterval

    @State private var thumbnails: [CGImage] = []
    @State private var activeHandle: Handle?
    @State private var dragStartTime: TimeInterval = 0
    @State private var dragEndTime: TimeInterval = 0
    @State private var dragTimelineOffset: CGFloat = 0
    @State private var timelineOffset: CGFloat = 0

    private enum Handle {
        case start
        case end
        case range
    }

    private var maximumSelectionDuration: TimeInterval {
        min(max(maxDuration, 0.1), duration)
    }

    private var minimumSelectionDuration: TimeInterval { 0.1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("拖动视频选择片段")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.header)
                Spacer()
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("起点 %1$@ · 选中 %2$@", comment: "Selected video extraction range"),
                    formatTimestamp(startTime) as NSString,
                    formatTimestamp(endTime - startTime) as NSString
                ))
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let maximumSelectionWidth = min(width * 0.5, max(width - 36, 1))
                let timelinePadding: CGFloat = 12
                let preferredTimelineScale = maximumSelectionWidth / CGFloat(maximumSelectionDuration)
                let preferredContentWidth = CGFloat(duration) * preferredTimelineScale
                let timelineFitsViewport = preferredContentWidth <= width
                let fitTimelineScale = max(width - timelinePadding * 2, 1) / CGFloat(duration)
                // 长片沿用原来的时间刻度；短片没有滚动空间时才铺满底片，
                // 让选框能在完整展示的缩略图上移动。
                let timelineScale = timelineFitsViewport
                    ? fitTimelineScale
                    : preferredTimelineScale
                let timelineContentWidth = CGFloat(duration) * timelineScale
                let selectedDuration = min(
                    max(endTime - startTime, minimumSelectionDuration),
                    maximumSelectionDuration
                )
                let selectionWidth = min(
                    max(28, CGFloat(selectedDuration) * timelineScale),
                    max(width - 24, 28)
                )
                let contentWidth = max(
                    width,
                    timelineContentWidth
                )
                let selectionX = timelinePadding + CGFloat(startTime) * timelineScale + timelineOffset
                let handleWidth: CGFloat = 18

                ZStack(alignment: .leading) {
                    // 内容层单独裁切，避免贴近左边界的起始 bar 被圆角裁掉。
                    thumbnailStrip(contentWidth: timelineContentWidth, height: 82)
                        .offset(x: timelineOffset + (timelineFitsViewport ? timelinePadding : 0))
                        .frame(width: width, height: 86, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // 遮罩和选区框固定在 viewport 层，不能放进会随着完整视频宽度
                    // 参与布局的 content 层。
                    TimelineInactiveRangeMask(
                        totalWidth: width,
                        leftWidth: selectionX,
                        rightWidth: width - selectionX - selectionWidth,
                        height: 82
                    )
                    .frame(width: width, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .zIndex(10)

                    // 选区边框放在遮罩之上。
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(LF.selectionStroke, lineWidth: 3)
                        .frame(width: selectionWidth, height: 86)
                        .offset(x: selectionX)
                        .shadow(color: LF.selectionText.opacity(0.32), radius: 3, y: 1)
                        .zIndex(20)

                    timelineHandle
                        .frame(width: handleWidth)
                        .offset(x: selectionX - handleWidth / 2)
                        .zIndex(30)
                    timelineHandle
                        .frame(width: handleWidth)
                        .offset(x: selectionX + selectionWidth - handleWidth / 2)
                        .zIndex(30)
                }
                .frame(width: width, height: 96)
                .contentShape(Rectangle())
                // 与外层纵向 ScrollView 同时接收事件；只有水平位移超过垂直位移
                // 才建立时间轴拖动会话，避免轻微上下滑动被时间轴抢走。
                .simultaneousGesture(
                    dragGesture(
                        selectionX: selectionX,
                        selectionWidth: selectionWidth,
                        timelineScale: timelineScale,
                        contentWidth: contentWidth,
                        viewportWidth: width
                    )
                )
            }
            .frame(height: 96)

            HStack {
                Text(formatTimestamp(0))
                Spacer()
                Label("拖动选区或边界", systemImage: "hand.draw")
                    .foregroundStyle(LF.selectionStroke)
                Spacer()
                Text(formatTimestamp(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(LF.textSecondary)
        }
        .task(id: url) {
            timelineOffset = 0
            activeHandle = nil
            await loadThumbnails()
        }
    }

    private func thumbnailStrip(contentWidth: CGFloat, height: CGFloat) -> some View {
        let count = max(thumbnails.count, 24)
        let itemWidth = max((contentWidth - CGFloat(count - 1)) / CGFloat(count), 1)

        return HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { index in
                if index < thumbnails.count {
                    Image(decorative: thumbnails[index], scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: itemWidth, height: height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [LF.selectionFill, LF.surface2],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: itemWidth, height: height)
                }
            }
        }
        .frame(width: contentWidth, height: height, alignment: .leading)
        .background(LF.surface2)
    }

    private var timelineHandle: some View {
        Capsule()
            .fill(LF.selectionStroke)
            .frame(width: 18, height: 96)
            .overlay {
                HStack(spacing: 3) {
                    Capsule()
                        .fill(LF.selectionText.opacity(0.72))
                        .frame(width: 2, height: 14)
                    Capsule()
                        .fill(LF.selectionText.opacity(0.72))
                        .frame(width: 2, height: 14)
                }
            }
            .overlay {
                Capsule()
                    .stroke(LF.selectionFill, lineWidth: 1)
            }
            .shadow(color: LF.selectionText.opacity(0.28), radius: 3, y: 1)
    }

    private func dragGesture(
        selectionX: CGFloat,
        selectionWidth: CGFloat,
        timelineScale: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if activeHandle == nil {
                    guard abs(value.translation.width) > abs(value.translation.height) else {
                        return
                    }
                    dragStartTime = startTime
                    dragEndTime = endTime
                    dragTimelineOffset = timelineOffset
                    activeHandle = handle(
                        at: value.startLocation.x,
                        selectionX: selectionX,
                        selectionWidth: selectionWidth
                    )
                }

                let delta = TimeInterval(value.translation.width / max(timelineScale, 1))
                switch activeHandle {
                case .some(.start):
                    let proposedStart = min(max(dragStartTime + delta, 0), dragEndTime - minimumSelectionDuration)
                    let maximumLengthStart = max(dragEndTime - maximumSelectionDuration, 0)
                    if proposedStart < maximumLengthStart {
                        // 从左侧继续拖动时已达到最大时长：两个 bar 一起向左移动。
                        startTime = proposedStart
                        endTime = min(proposedStart + maximumSelectionDuration, duration)
                    } else {
                        startTime = proposedStart
                    }
                case .some(.end):
                    let minimum = min(duration, dragStartTime + minimumSelectionDuration)
                    let proposedEnd = min(max(dragEndTime + delta, minimum), duration)
                    let maximumLengthEnd = dragStartTime + maximumSelectionDuration
                    if proposedEnd > maximumLengthEnd {
                        // 达到最大时长后继续向右拖：整段选区一起向右移动，长度保持不变。
                        let shiftedStart = min(
                            proposedEnd - maximumSelectionDuration,
                            max(duration - maximumSelectionDuration, 0)
                        )
                        startTime = max(shiftedStart, 0)
                        endTime = min(startTime + maximumSelectionDuration, duration)
                    } else {
                        endTime = proposedEnd
                    }
                case .some(.range), nil:
                    let length = dragEndTime - dragStartTime
                    let maximumStart = max(duration - length, 0)
                    let minimumOffset = -max(contentWidth - viewportWidth, 0)
                    if contentWidth - viewportWidth <= 0.5 {
                        // 短片全部可见，底片无处可滚；只移动选中框。
                        let newStart = min(max(dragStartTime + delta, 0), maximumStart)
                        timelineOffset = dragTimelineOffset
                        startTime = newStart
                        endTime = newStart + length
                        break
                    }

                    // 长片沿用原行为：拖动选区或底片时，底片跟手移动，选框留在原位。
                    let timelineDelta = -delta
                    let newStart = min(max(dragStartTime + timelineDelta, 0), maximumStart)
                    let offset = dragTimelineOffset - CGFloat(newStart - dragStartTime) * timelineScale
                    timelineOffset = min(max(offset, minimumOffset), 0)
                    startTime = newStart
                    endTime = newStart + length
                }
            }
            .onEnded { _ in
                activeHandle = nil
            }
    }

    private func handle(at x: CGFloat, selectionX: CGFloat, selectionWidth: CGFloat) -> Handle {
        let left = selectionX
        let right = selectionX + selectionWidth
        // 热区只略大于视觉 bar，把 bar 以外的区域留给时间窗口平移。
        // 当选区很短、两侧热区重叠时，按距离最近的一侧处理，避免总是误判成起点。
        let hitSlop: CGFloat = 10
        let distanceToStart = abs(x - left)
        let distanceToEnd = abs(x - right)
        if distanceToStart <= hitSlop || distanceToEnd <= hitSlop {
            return distanceToStart <= distanceToEnd ? .start : .end
        }
        return .range
    }

    private func loadThumbnails() async {
        let requestedURL = url
        let requestedDuration = duration
        let images = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: requestedURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let count = 24
            return (0..<count).compactMap { index -> CGImage? in
                let progress = Double(index) / Double(max(count - 1, 1))
                let time = CMTime(
                    seconds: requestedDuration * progress,
                    preferredTimescale: 600
                )
                return try? generator.copyCGImage(at: time, actualTime: nil)
            }
        }.value

        guard !Task.isCancelled else { return }
        thumbnails = images
    }

    private func formatTimestamp(_ value: TimeInterval) -> String {
        let safeValue = max(value, 0)
        return String(format: "%d:%04.1f", Int(safeValue) / 60, safeValue.truncatingRemainder(dividingBy: 60))
    }
}

struct ClipCell: View {
    let clip: SegmentedClip
    let onOpen: (() -> Void)?
    let onDelete: (() -> Void)?
    let deleteAccessibilityLabel: String
    let deleteAccessibilityIdentifier: String
    @State private var isPlaying = false

    init(
        clip: SegmentedClip,
        onOpen: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        deleteAccessibilityLabel: String = "删除素材",
        deleteAccessibilityIdentifier: String? = nil
    ) {
        self.clip = clip
        self.onOpen = onOpen
        self.onDelete = onDelete
        self.deleteAccessibilityLabel = deleteAccessibilityLabel
        self.deleteAccessibilityIdentifier = deleteAccessibilityIdentifier ?? "clip-cell-delete-\(clip.id)"
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                AnimatedClipPreview(
                    clip: clip,
                    maxPixelSize: FrameCache.previewThumbnailMaxPixelSize,
                    isPlaying: $isPlaying
                )
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .highPriorityGesture(
                SpatialTapGesture().onEnded { value in
                    let deleteArea = CGRect(x: 0, y: 0, width: 44, height: 44)
                    if onDelete != nil, deleteArea.contains(value.location) {
                        return
                    }
                    let playArea = CGRect(x: 0, y: 56, width: 72, height: 64)
                    if clip.frameCount > 1, playArea.contains(value.location) {
                        isPlaying.toggle()
                    } else {
                        onOpen?()
                    }
                }
            )
            .overlay(alignment: .bottomLeading) {
                if clip.frameCount > 1 {
                    // 这里只负责显示，真正的点击分流由预览区的 SpatialTapGesture 处理，
                    // 避免外层详情点击手势再次抢走播放入口。
                    ClipPreviewBadgeIcon(
                        systemName: isPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(width: 44, height: 44)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if clip.audioURL != nil {
                    ClipPreviewBadgeIcon(
                        systemName: "waveform",
                        foregroundStyle: LF.gold
                    )
                    .frame(width: 44, height: 44)
                }
            }
            .overlay(alignment: .topLeading) {
                if let onDelete {
                    Button(action: onDelete) {
                        ClipPreviewBadgeIcon(systemName: "trash")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(deleteAccessibilityLabel)
                    .accessibilityIdentifier(deleteAccessibilityIdentifier)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !clip.excludedFrames.isEmpty {
                    ClipPreviewBadgeIcon(
                        systemName: "square.grid.3x3",
                        foregroundStyle: LF.gold
                    )
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("已修改帧")
                } else if clip.edgeStyle != .none {
                    ClipPreviewBadgeIcon(
                        systemName: "square.dashed",
                        foregroundStyle: LF.gold
                    )
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("已设置边缘效果")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(LF.surface2, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("%1$lld×%2$lld · %3$lld fps · %4$lld 帧", comment: "Clip dimensions and frame rate"),
                    Int64(clip.width), Int64(clip.height), Int64(clip.fps.rounded()), Int64(clip.frameCount)
                ))
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                onOpen?()
            }
        }
    }
}

/// 素材详情页的预览按源素材比例展示，不复用素材库的固定高度卡片。
private struct ClipDetailPreview: View {
    let clip: SegmentedClip
    @Binding var isPlaying: Bool
    let onCrop: () -> Void
    let onRotateCounterclockwise: () -> Void
    let onRotateClockwise: () -> Void

    /// 详情页只负责检查原始素材，不在这里模拟编辑器/导出的边缘效果。
    private var unstyledClip: SegmentedClip {
        var value = clip
        value.edgeStyle = .none
        return value
    }

    private var aspectRatio: CGFloat {
        CGFloat(max(clip.renderedWidth, 1)) / CGFloat(max(clip.renderedHeight, 1))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AnimatedClipPreview(
                clip: unstyledClip,
                maxPixelSize: FrameCache.previewThumbnailMaxPixelSize,
                isPlaying: $isPlaying
            )
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if clip.frameCount > 1 {
                ClipPreviewPlayButton(clip: clip, isPlaying: $isPlaying)
                    .padding(4)
            }

            HStack(spacing: 6) {
                ClipPreviewActionButton(
                    systemName: "rotate.left",
                    accessibilityLabel: "逆时针旋转90度",
                    action: onRotateCounterclockwise
                )
                ClipPreviewActionButton(
                    systemName: "rotate.right",
                    accessibilityLabel: "顺时针旋转90度",
                    action: onRotateClockwise
                )
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ClipPreviewActionButton(
                systemName: "crop",
                accessibilityLabel: "裁剪素材",
                action: onCrop
            )
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LF.surface2, lineWidth: 1)
        }
    }
}

/// 贴在素材预览画布上的轻量图标操作，与裁剪入口保持同一视觉样式。
private struct ClipPreviewActionButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 素材详情页复用编辑器的裁剪框交互；这里只保存素材自身的归一化裁剪区域。
private struct ClipCropEditorView: View {
    let clip: SegmentedClip
    let initialRect: CGRect
    let onCancel: () -> Void
    let onFinish: (CGRect?) -> Void
    @State private var draftRect: CGRect
    @State private var isPlaying = false

    init(
        clip: SegmentedClip,
        initialRect: CGRect,
        onCancel: @escaping () -> Void,
        onFinish: @escaping (CGRect?) -> Void
    ) {
        self.clip = clip
        self.initialRect = initialRect
        self.onCancel = onCancel
        self.onFinish = onFinish
        _draftRect = State(initialValue: initialRect)
    }

    private var contentRect: CGRect {
        CGRect(
            x: 0,
            y: 0,
                    width: CGFloat(max(clip.orientedWidth, 1)),
                    height: CGFloat(max(clip.orientedHeight, 1))
        )
    }

    private var previewClip: SegmentedClip {
        var value = clip
        value.edgeStyle = .none
        value.cropRect = nil
        return value
    }

    private var pixelCropRect: Binding<CGRect?> {
        Binding(
            get: {
                CGRect(
                    x: contentRect.width * draftRect.minX,
                    y: contentRect.height * draftRect.minY,
                    width: contentRect.width * draftRect.width,
                    height: contentRect.height * draftRect.height
                )
            },
            set: { value in
                guard let value else { return }
                draftRect = CGRect(
                    x: value.minX / max(contentRect.width, 1),
                    y: value.minY / max(contentRect.height, 1),
                    width: value.width / max(contentRect.width, 1),
                    height: value.height / max(contentRect.height, 1)
                )
            }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ZStack {
                    AnimatedClipPreview(
                        clip: previewClip,
                        maxPixelSize: FrameCache.previewThumbnailMaxPixelSize,
                        isPlaying: $isPlaying
                    )
                    CropOverlayView(
                        contentRect: contentRect,
                        minimumCropSize: 50,
                        cropRect: pixelCropRect
                    )
                }
                .aspectRatio(
                    CGFloat(max(clip.orientedWidth, 1)) / CGFloat(max(clip.orientedHeight, 1)),
                    contentMode: .fit
                )
                .padding(20)
            }
            .lfNavigationTitle("裁剪素材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
                        onFinish(draftRect == full ? nil : draftRect)
                    }
                }
            }
            .magicBackground()
        }
    }
}

/// 素材详情页：单击素材后进入，集中处理原始预览、帧编辑和文件夹管理。
struct ClipMenuView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let clip: SegmentedClip
    let onClose: () -> Void
    @State private var showFrameEditor = false
    @State private var isPlayingPreview = false
    @State private var deleteAlert: DeleteAlert?
    @State private var referencedWorkNames: [String] = []
    @State private var isDeletingClip = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var isExportingGIF = false
    @State private var exportGIFError: String?
    @State private var exportGIFTask: Task<Void, Never>?
    @State private var clipExportState = ClipExportState()
    @State private var gifPresets: [GIFExportPreset] = []
    @State private var gifResolution: ExportResolution = .p720
    @State private var gifFPS = 15.0
    @State private var isEstimatingGIF = false
    @State private var isCroppingClip = false
    @State private var cropRect: CGRect?
    @State private var didManuallySelectGIFPreset = false

    /// 读取最新值，避免详情页打开后修改样式仍显示旧状态。
    private var currentClip: SegmentedClip {
        appState.clips.first(where: { $0.id == clip.id }) ?? clip
    }

    private var hasCurrentExport: Bool {
        clipExportState.isCurrent(
            for: currentClip.rotationQuarterTurns,
            cropKey: currentClip.cropCacheKey,
            resolution: gifResolution,
            fps: gifFPS
        )
    }

    private var gifResolutionOptions: [ExportResolution] {
        GIFExportPreset.resolutionOptions(
            maxSourceDimension: CGFloat(max(currentClip.renderedWidth, currentClip.renderedHeight, 1))
        )
    }

    private var gifFPSOptions: [Double] {
        GIFExportPreset.fpsOptions(maxSourceFPS: currentClip.fps)
    }

    /// 素材当前是否已在指定文件夹。
    private func isFiled(_ folderID: String) -> Bool {
        appState.folders.contains { $0.id == folderID && $0.clipIDs.contains(clip.id) }
    }

    private func close() {
        onClose()
        dismiss()
    }

    var body: some View {
        NavigationStack {
            detailScrollView
            .lfNavigationTitle("素材详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        requestDeleteClip()
                    } label: {
                        Image(systemName: isDeletingClip ? "hourglass" : "trash")
                    }
                    .disabled(isDeletingClip)
                    .accessibilityLabel("删除素材")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.semibold))
                    }
                    .accessibilityLabel("完成")
                }
            }
            .magicBackground()
        }
        .sheet(isPresented: $showFrameEditor) {
            FrameGridView(clipID: clip.id)
                .environmentObject(appState)
        }
        .alert(item: $deleteAlert) { alert in
            switch alert {
            case .confirm:
                return Alert(
                    title: Text("删除素材？"),
                    message: Text("删除后无法恢复，但不会影响素材库中的其他内容。"),
                    primaryButton: .destructive(Text("删除")) {
                        guard !isDeletingClip else { return }
                        isDeletingClip = true
                        appState.deleteClip(clip.id)
                        close()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .referenced:
                return Alert(
                    title: Text("素材正在使用中"),
                    message: Text(String.localizedStringWithFormat(
                        NSLocalizedString("请先从以下作品中移除它，再删除素材：\n%1$@", comment: "Asset is used by these works"),
                        referencedWorkNames.joined(separator: "、") as NSString
                    )),
                    dismissButton: .cancel(Text("取消"))
                )
            }
        }
        .alert("重命名素材", isPresented: $showRenameAlert) {
            TextField("素材名称", text: $renameText)
            Button("保存") {
                appState.renameClip(clip.id, to: renameText)
            }
            Button("取消", role: .cancel) {}
        }
        .alert("GIF 导出失败", isPresented: Binding(
            get: { exportGIFError != nil },
            set: { if !$0 { exportGIFError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportGIFError ?? "请稍后重试。")
        }
        .onDisappear {
            exportGIFTask?.cancel()
        }
        .task(id: "\(currentClip.id)-\(currentClip.rotationQuarterTurns)-\(currentClip.cropCacheKey)") {
            await loadGIFPresets()
        }
        .fullScreenCover(isPresented: $isCroppingClip) {
            ClipCropEditorView(
                clip: currentClip,
                initialRect: cropRect ?? currentClip.normalizedCropRect,
                onCancel: { isCroppingClip = false },
                onFinish: { rect in
                    appState.setClipCrop(clip.id, rect)
                    clipExportState = ClipExportState()
                    isCroppingClip = false
                }
            )
        }
    }

    private var detailScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                clipIdentityHeader
                ClipDetailPreview(
                    clip: currentClip,
                    isPlaying: $isPlayingPreview,
                    onCrop: beginClipCrop,
                    onRotateCounterclockwise: { rotateClip(clockwise: false) },
                    onRotateClockwise: { rotateClip(clockwise: true) }
                )
                gifExportSection
                // 帧选择入口暂时隐藏；保留 frameEditorButton、sheet 状态和 FrameGridView，后续可恢复。
                // frameEditorButton
                foldersSection
            }
            .padding(20)
        }
    }

    private var gifExportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.headline)
                    .foregroundStyle(LF.gold)
                    .frame(width: 34, height: 34)
                    .background(LF.selectionFill, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("透明 GIF")
                        .font(.subheadline.weight(.semibold))
                    Text("透明背景")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                Picker("尺寸", selection: Binding(
                    get: { gifResolution },
                    set: {
                        gifResolution = $0
                        didManuallySelectGIFPreset = true
                    }
                )) {
                    ForEach(gifResolutionOptions) { resolution in
                        Text(resolution.gifTitle(for: CGFloat(max(currentClip.renderedWidth, currentClip.renderedHeight, 1))))
                            .tag(resolution)
                    }
                }
                .pickerStyle(.menu)

                Picker("帧率", selection: Binding(
                    get: { gifFPS },
                    set: {
                        gifFPS = $0
                        didManuallySelectGIFPreset = true
                    }
                )) {
                    ForEach(gifFPSOptions, id: \.self) { fps in
                        Text("\(Int(fps)) fps").tag(fps)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                if isEstimatingGIF {
                    ProgressView()
                        .controlSize(.small)
                } else if let selectedPreset {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("约 %1$@", comment: "Estimated file size"),
                        FileSizeText.string(fromByteCount: selectedPreset.estimatedBytes) as NSString
                    ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selectedPreset.estimatedBytes <= 10 * 1024 * 1024 ? LF.textSecondary : LF.destructive)
                }
            }
            .font(.caption.weight(.medium))

            Text("默认选择最接近 10 MB 的规格，实际大小以导出结果为准")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)

            if isExportingGIF {
                HStack(spacing: 10) {
                    ProgressView(value: appState.exportProgress)
                        .tint(LF.gold)
                    Text("\(Int(appState.exportProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                }
            }

            if !hasCurrentExport {
                HStack(spacing: 10) {
                    Button {
                        if isExportingGIF {
                            exportGIFTask?.cancel()
                        } else {
                            exportTransparentGIF()
                        }
                    } label: {
                        Label(
                            isExportingGIF ? "取消导出" : "保存到相册",
                            systemImage: isExportingGIF ? "xmark" : "photo.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isExportingGIF ? LF.header : LF.actionPrimary)
                    .disabled(isEstimatingGIF && !isExportingGIF)
                }
            }

            if hasCurrentExport {
                Label("GIF 已保存到相册。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(LF.selectionText)
            }
        }
        .padding(14)
        .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func exportTransparentGIF() {
        exportGIFError = nil
        isExportingGIF = true
        let clipID = clip.id
        exportGIFTask = Task { @MainActor in
            defer {
                isExportingGIF = false
                exportGIFTask = nil
            }
            do {
                _ = try await appState.exportClipAsTransparentGIF(
                    clipID,
                    resolution: gifResolution,
                    fps: gifFPS
                )
                let exportedClip = appState.clips.first(where: { $0.id == clipID }) ?? clip
                clipExportState.markExported(
                    for: exportedClip.rotationQuarterTurns,
                    cropKey: exportedClip.cropCacheKey,
                    resolution: gifResolution,
                    fps: gifFPS
                )
            } catch is CancellationError {
                // 用户主动取消，不显示错误。
            } catch ExportError.cancelled {
                // 用户主动取消，不显示错误。
            } catch {
                exportGIFError = error.localizedDescription
            }
        }
    }

    private func beginClipCrop() {
        cropRect = currentClip.normalizedCropRect
        isCroppingClip = true
    }

    private var selectedPreset: GIFExportPreset? {
        gifPresets.first { $0.resolution == gifResolution && abs($0.fps - gifFPS) < 0.01 }
    }

    private func loadGIFPresets() async {
        let resolutionOptions = gifResolutionOptions
        let fpsOptions = gifFPSOptions
        if !resolutionOptions.contains(gifResolution) {
            gifResolution = resolutionOptions.last ?? gifResolution
        }
        if !fpsOptions.contains(where: { abs($0 - gifFPS) < 0.01 }) {
            gifFPS = fpsOptions.last ?? gifFPS
        }
        isEstimatingGIF = true
        defer { isEstimatingGIF = false }
        do {
            let presets = try await appState.estimateClipGIFPresets(
                clip.id,
                resolutions: resolutionOptions,
                fpsOptions: fpsOptions
            )
            guard !Task.isCancelled, !presets.isEmpty else { return }
            gifPresets = presets
            if !didManuallySelectGIFPreset,
               let preferred = GIFExportPreset.defaultPreset(from: presets) {
                gifResolution = preferred.resolution
                gifFPS = preferred.fps
            }
        } catch {
            gifPresets = []
        }
    }

    private var clipIdentityHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(currentClip.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("%1$lld×%2$lld · %3$lld fps · %4$lld 帧", comment: "Clip dimensions and frame rate"),
                    Int64(currentClip.renderedWidth), Int64(currentClip.renderedHeight), Int64(currentClip.fps.rounded()), Int64(currentClip.frameCount)
                ))
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }
            Spacer()
            Button {
                renameText = currentClip.name
                showRenameAlert = true
            } label: {
                Image(systemName: "pencil.line")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(LF.surface2, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑素材名称")
        }
    }

    private func rotateClip(clockwise: Bool) {
        if reduceMotion {
            applyClipRotation(clockwise: clockwise)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                applyClipRotation(clockwise: clockwise)
            }
        }
    }

    private func applyClipRotation(clockwise: Bool) {
        if clockwise {
            appState.rotateClip(clip.id)
        } else {
            appState.rotateClipCounterclockwise(clip.id)
        }
        clipExportState = ClipExportState()
    }

    private var frameEditorButton: some View {
        Button {
            showFrameEditor = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.3x3")
                    .foregroundStyle(LF.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text("编辑帧")
                        .font(.subheadline.weight(.semibold))
                    Text("取舍帧，让动态素材更轻、更顺")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)
            }
            .padding(14)
            .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文件夹")
                    .font(.headline)
                    .foregroundStyle(LF.header)
                Spacer()
                Text("选择后会移动到该文件夹")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }

            if appState.folders.isEmpty {
                Text("还没有文件夹，可先在素材库创建")
                    .font(.subheadline)
                    .foregroundStyle(LF.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(appState.folders) { folder in
                    folderButton(folder)
                }
            }
        }
    }

    private func folderButton(_ folder: LibraryFolder) -> some View {
        let filed = isFiled(folder.id)
        return Button {
            appState.moveClip(clip.id, toFolder: filed ? nil : folder.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: filed ? "folder.fill" : "folder")
                    .foregroundStyle(LF.folderIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .lineLimit(1)
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("%1$lld 个素材", comment: "Clip count in folder"),
                        Int64(folder.clipIDs.count)
                    ))
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer()
                Image(systemName: filed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(filed ? LF.gold : LF.textSecondary)
            }
            .padding(14)
            .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func requestDeleteClip() {
        referencedWorkNames = appState.worksReferencingClip(clip.id).map(\.name)
        if referencedWorkNames.isEmpty {
            deleteAlert = .confirm
        } else {
            deleteAlert = .referenced
        }
    }
}

private enum DeleteAlert: Hashable, Identifiable {
    case confirm
    case referenced

    var id: Self { self }
}

/// 拖拽预览：小尺寸素材缩略图（长按拖到文件夹时用）
struct ClipDragPreview: View {
    let clip: SegmentedClip

    var body: some View {
        Group {
            ClipThumbnailView(clip: clip, index: 0, maxPixelSize: 88)
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(LF.gold, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

/// 应用 EXIF orientation：把 UIImage 重绘为像素方向正确的 CGImage
private extension UIImage {
    func fixedOrientation() -> CGImage? {
        guard imageOrientation != .up else { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let fixed = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return fixed.cgImage
    }
}
