import AVFoundation
import AVKit
import CoreGraphics
import CoreImage
import LivingFrameCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isShowingExtractionPicker = false
    @State private var liveConversionPickerItems: [PhotosPickerItem] = []
    @State private var isShowingLiveConversionPicker = false
    @State private var videoConversionPickerItems: [PhotosPickerItem] = []
    @State private var isShowingVideoConversionPicker = false
    @State private var conversionTask: Task<Void, Never>?
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0
    @State private var conversionTarget: MediaConversionService.Target = .livePhoto
    @State private var conversionTitle = ""
    @State private var conversionErrorMessage: String?
    @State private var conversionResultMessage: String?
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
    /// 记录当前打开相册选择器的剪影类型，动态剪影与静态贴纸分别从独立入口进入。
    @State private var pendingExtractKind: ExtractKind = .live
    @State private var dynamicCutoutSymbolAnimation = 0
    @State private var staticStickerSymbolAnimation = 0
    @State private var liveConversionSymbolAnimation = 0
    @State private var videoConversionSymbolAnimation = 0
    /// 超过单个素材最长时长的视频，在动态提取前选择源视频范围。
    @State private var pendingVideoRange: PendingVideoRange?
    /// 动态素材完成主体分析后，等待用户选择需要保留的主体。
    @State private var pendingSubjectSelection: PendingSubjectSelection?
    /// 在 Vision 分析前先让用户圈出大致范围，减少后续主体选择的歧义。
    @State private var pendingSubjectRegionSelection: PendingSubjectRegionSelection?
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

    private struct PendingVideoRange: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let duration: TimeInterval
        let maxDuration: TimeInterval
        let confirmTitle: LocalizedStringKey
        var resume: (ClosedRange<TimeInterval>?) -> Void

        init(
            url: URL,
            name: String,
            duration: TimeInterval,
            maxDuration: TimeInterval,
            confirmTitle: LocalizedStringKey = "生成剪影",
            resume: @escaping (ClosedRange<TimeInterval>?) -> Void
        ) {
            self.url = url
            self.name = name
            self.duration = duration
            self.maxDuration = maxDuration
            self.confirmTitle = confirmTitle
            self.resume = resume
        }
    }

    private struct PendingSubjectSelection: Identifiable {
        let id = UUID()
        let analysis: VideoSegmentationAnalysis
        let initialRegion: [CGPoint]?
        let debugRegion: [CGPoint]?
        var resume: (Set<Int>?, [CGPoint]?) -> Void
    }

    private struct SubjectRegionChoice {
        let confirmed: Bool
        let points: [CGPoint]?

        init(
            confirmed: Bool,
            points: [CGPoint]? = nil
        ) {
            self.confirmed = confirmed
            self.points = points
        }
    }

    private struct PendingSubjectRegionSelection: Identifiable {
        let id = UUID()
        let image: CGImage
        var resume: (SubjectRegionChoice) -> Void
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
                    if isConverting {
                        conversionCard
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
            .animation(.easeInOut(duration: 0.22), value: isConverting)
            .navigationTitle("转换")
            .navigationBarTitleDisplayMode(.large)
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
            .alert(
                NSLocalizedString("转换失败", comment: "Media conversion failure title"),
                isPresented: Binding(
                    get: { conversionErrorMessage != nil },
                    set: { if !$0 { conversionErrorMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("知道了", comment: "Dismiss conversion error"), role: .cancel) {
                    conversionErrorMessage = nil
                }
            } message: {
                Text(conversionErrorMessage ?? "")
            }
            .alert(
                NSLocalizedString("转换完成", comment: "Media conversion success title"),
                isPresented: Binding(
                    get: { conversionResultMessage != nil },
                    set: { if !$0 { conversionResultMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("知道了", comment: "Dismiss conversion success"), role: .cancel) {
                    conversionResultMessage = nil
                }
            } message: {
                Text(conversionResultMessage ?? "")
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
                    confirmTitle: request.confirmTitle,
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
            .sheet(item: $pendingSubjectSelection, onDismiss: {
                pendingSubjectSelection?.resume(nil, nil)
                pendingSubjectSelection = nil
            }) { request in
                SubjectSelectionView(
                    analysis: request.analysis,
                    initialLassoPoints: request.initialRegion ?? [],
                    debugLassoPoints: request.debugRegion ?? [],
                    onCancel: {
                        request.resume(nil, nil)
                        pendingSubjectSelection = nil
                    },
                    onConfirm: { selectedIDs, selectionRegion in
                        request.resume(selectedIDs, selectionRegion)
                        pendingSubjectSelection = nil
                    }
                )
            }
            .sheet(item: $pendingSubjectRegionSelection, onDismiss: {
                pendingSubjectRegionSelection?.resume(SubjectRegionChoice(confirmed: false, points: nil))
                pendingSubjectRegionSelection = nil
            }) { request in
                InitialSubjectRegionPickerView(
                    image: request.image,
                    onCancel: {
                        request.resume(SubjectRegionChoice(confirmed: false, points: nil))
                        pendingSubjectRegionSelection = nil
                    },
                    onSkip: {
                        request.resume(SubjectRegionChoice(confirmed: true, points: nil))
                        pendingSubjectRegionSelection = nil
                    },
                    onConfirm: { points in
                        request.resume(SubjectRegionChoice(
                            confirmed: true,
                            points: points
                        ))
                        pendingSubjectRegionSelection = nil
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
                conversionTask?.cancel()
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - 素材入口

    private var pickerSection: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 12
        ) {
            extractionPickerControl(kind: .live)
            extractionPickerControl(kind: .static)
            liveConversionPickerControl
            videoConversionPickerControl
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
        .onChange(of: isShowingLiveConversionPicker) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            Task { @MainActor in
                await Task.yield()
                handleConversionSelection(
                    liveConversionPickerItems,
                    target: .livePhoto
                )
            }
        }
        .onChange(of: isShowingVideoConversionPicker) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            Task { @MainActor in
                await Task.yield()
                handleConversionSelection(
                    videoConversionPickerItems,
                    target: .video
                )
            }
        }
    }

    @ViewBuilder
    private func extractionPickerControl(kind: ExtractKind) -> some View {
        let isDynamic = kind == .live
        let title: LocalizedStringKey = isDynamic ? "动态剪影" : "静态贴纸"
        let button = Button {
            pendingExtractKind = kind
            if isDynamic {
                dynamicCutoutSymbolAnimation += 1
            } else {
                staticStickerSymbolAnimation += 1
            }
            isShowingExtractionPicker = true
        } label: {
            conversionActionCard(
                title: title,
                subtitle: nil,
                systemImage: isDynamic ? "scissors" : "wand.and.outline",
                compact: true,
                symbolAnimation: isDynamic
                    ? dynamicCutoutSymbolAnimation
                    : staticStickerSymbolAnimation
            )
        }
        .lfAnimatedPlainButtonStyle()
        .photosPicker(
            isPresented: $isShowingExtractionPicker,
            selection: $pickerItems,
            maxSelectionCount: 5,
            selectionBehavior: .ordered,
            matching: .any(of: [.videos, .livePhotos, .images])
        )
        .disabled(isMediaBusy)
        .accessibilityIdentifier(isDynamic ? "library-extraction-entry" : "library-static-cutout-entry")
        .accessibilityLabel(title)
        .accessibilityHint(isDynamic ? "选择视频、Live Photo 或照片" : "选择照片、Live Photo 或视频的首帧")

        if isDynamic {
            button.accessibilityFocused($extractionEntryFocused)
        } else {
            button
        }
    }

    private var liveConversionPickerControl: some View {
        Button {
            liveConversionSymbolAnimation += 1
            isShowingLiveConversionPicker = true
        } label: {
            conversionActionCard(
                title: "转为 Live Photo",
                subtitle: nil,
                systemImage: "livephoto",
                compact: true,
                symbolAnimation: liveConversionSymbolAnimation
            )
        }
        .lfAnimatedPlainButtonStyle()
        .photosPicker(
            isPresented: $isShowingLiveConversionPicker,
            selection: $liveConversionPickerItems,
            maxSelectionCount: 5,
            selectionBehavior: .ordered,
            matching: .any(of: [
                .videos,
                .playbackStyle(.imageAnimated)
            ])
        )
        .disabled(isMediaBusy)
        .accessibilityIdentifier("library-convert-live-entry")
        .accessibilityLabel("转为 Live Photo")
        .accessibilityHint("相册中只处理 GIF 和视频")
    }

    private var videoConversionPickerControl: some View {
        Button {
            videoConversionSymbolAnimation += 1
            isShowingVideoConversionPicker = true
        } label: {
            conversionActionCard(
                title: "转为视频",
                subtitle: nil,
                systemImage: "video",
                compact: true,
                symbolAnimation: videoConversionSymbolAnimation
            )
        }
        .lfAnimatedPlainButtonStyle()
        .photosPicker(
            isPresented: $isShowingVideoConversionPicker,
            selection: $videoConversionPickerItems,
            maxSelectionCount: 5,
            selectionBehavior: .ordered,
            matching: .any(of: [
                .livePhotos,
                .playbackStyle(.imageAnimated)
            ])
        )
        .disabled(isMediaBusy)
        .accessibilityIdentifier("library-convert-video-entry")
        .accessibilityLabel("转为视频")
        .accessibilityHint("从相册选择 Live Photo 或 GIF")
    }

    private func conversionActionCard(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey?,
        systemImage: String,
        compact: Bool = false,
        symbolAnimation: Int = 0
    ) -> some View {
        SectionCard(title: nil) {
            HStack(spacing: compact ? 10 : 14) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 22 : 28, weight: .semibold))
                    .symbolEffect(.bounce, value: symbolAnimation)
                    .foregroundStyle(LF.gold)
                    .frame(width: compact ? 34 : 42, height: compact ? 34 : 42)
                    .background(LF.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .lineLimit(compact ? 2 : nil)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(compact ? 2 : nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LF.textSecondary)
            }
            .padding(.vertical, compact ? 0 : 2)
            .frame(maxWidth: .infinity, minHeight: compact ? 64 : 0, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private var isMediaBusy: Bool {
        isDownloading || isExtractionActive || isConverting
    }

    private func handleExtractionSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        // Clear only after the picker has closed; clearing its live selection
        // while it is open dismisses it after the first tap.
        pickerItems.removeAll()
        // A new selection starts a new retry batch. Never let an older
        // failed URL remain eligible for a later retry action.
        lastImportedSources.forEach { $0.removeTemporaryFiles() }
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
            guard !Task.isCancelled else {
                sources.forEach { $0.removeTemporaryFiles() }
                return
            }
            guard !sources.isEmpty else {
                batchFailureTitle = "导入失败"
                batchFailureMessageText = batchFailureMessage(
                    successCount: 0,
                    importFailureCount: importFailures.count,
                    extractionFailureCount: 0
                )
                return
            }

            // 2. 视频按用户点击的独立入口提取为动态剪影或静态贴纸。
            let selectedKind = pendingExtractKind
            let kinds = sources.map { isVideoSource($0) ? selectedKind : .static }
            startExtraction(
                sources: sources,
                kinds: kinds,
                importFailures: importFailures,
                importFailureCount: importFailures.count
            )
        }
    }

    private func handleConversionSelection(
        _ items: [PhotosPickerItem],
        target: MediaConversionService.Target
    ) {
        guard !items.isEmpty else { return }
        let itemSummaries = items.map { item in
            let types = item.supportedContentTypes.map(\.identifier).joined(separator: ",")
            return "\(item.itemIdentifier ?? "nil"): \(types)"
        }
        LogStore.log(
            "xdz.convert.selection target=\(target) count=\(items.count) items=\(itemSummaries.joined(separator: " | "))"
        )
        switch target {
        case .livePhoto:
            liveConversionPickerItems.removeAll()
        case .video:
            videoConversionPickerItems.removeAll()
        }

        conversionTask?.cancel()
        conversionErrorMessage = nil
        conversionResultMessage = nil
        conversionProgress = 0
        conversionTarget = target
        conversionTitle = target == .livePhoto ? "正在转换为 Live Photo" : "正在转换为视频"
        isConverting = true
        // PhotosPickerItem.loadTransferable 可能需要先从 iCloud 取回动图，
        // 但它不提供可观察的百分比进度；统一显示下载卡片，未知进度时使用转圈。
        isDownloading = true
        downloadProgress = nil

        conversionTask = Task { @MainActor in
            var successCount = 0
            var failureCount = 0
            var firstFailure: String?
            var firstWarning: String?

            for (index, item) in items.enumerated() {
                guard !Task.isCancelled else { break }
                conversionTitle = String.localizedStringWithFormat(
                    NSLocalizedString("正在处理第 %1$lld/%2$lld 个素材", comment: "Conversion queue progress"),
                    Int64(index + 1),
                    Int64(items.count)
                )
                conversionProgress = 0
                isDownloading = true
                downloadProgress = nil

                guard let source = await loadConversionSource(item, target: target) else {
                    isDownloading = false
                    failureCount += 1
                    firstFailure = firstFailure ?? conversionInputFailureMessage(for: target)
                    continue
                }
                isDownloading = false
                downloadProgress = nil
                defer { source.removeTemporaryFiles() }

                do {
                    let sourceRange: ClosedRange<TimeInterval>?
                    if target == .livePhoto,
                       isVideoConversionSource(source.fileExtension) {
                        let duration = await videoDuration(of: source.url)
                        if duration > MediaConversionService.livePhotoMaximumDuration {
                            sourceRange = await withCheckedContinuation { continuation in
                                pendingVideoRange = PendingVideoRange(
                                    url: source.url,
                                    name: source.name,
                                    duration: duration,
                                    maxDuration: MediaConversionService.livePhotoMaximumDuration,
                                    confirmTitle: "转为 Live Photo"
                                ) { selectedRange in
                                    continuation.resume(returning: selectedRange)
                                }
                            }
                            guard sourceRange != nil else { continue }
                        } else {
                            sourceRange = nil
                        }
                    } else {
                        sourceRange = nil
                    }

                    try await MediaConversionService().convert(
                        sourceURL: source.url,
                        sourceName: source.name,
                        sourceFileExtension: source.fileExtension,
                        target: target,
                        sourceRange: sourceRange,
                        progress: { value in
                            Task { @MainActor in
                                self.conversionProgress = min(max(value, 0), 1)
                            }
                        },
                        warning: { message in
                            firstWarning = firstWarning ?? message
                        }
                    )
                    successCount += 1
                } catch {
                    if Task.isCancelled { break }
                    failureCount += 1
                    firstFailure = firstFailure ?? (error as? LocalizedError)?.errorDescription
                }
            }

            isConverting = false
            isDownloading = false
            downloadProgress = nil
            conversionProgress = 0
            guard !Task.isCancelled else { return }

            if failureCount > 0 {
                let failureDetail = [
                    firstFailure ?? NSLocalizedString("请重新选择素材后重试。", comment: "Conversion retry suggestion"),
                    firstWarning
                ]
                .compactMap { $0 }
                .joined(separator: "\n")
                conversionErrorMessage = String.localizedStringWithFormat(
                    NSLocalizedString(
                        "成功转换 %1$lld 项，%2$lld 项失败。%@",
                        comment: "Mixed conversion result"
                    ),
                    Int64(successCount),
                    Int64(failureCount),
                    failureDetail
                )
            } else if successCount > 0 {
                let successMessage = String.localizedStringWithFormat(
                    NSLocalizedString(
                        "已转换并保存 %1$lld 项素材到照片。",
                        comment: "Conversion success result"
                    ),
                    Int64(successCount)
                )
                conversionResultMessage = [successMessage, firstWarning]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
        }
    }

    private func loadConversionSource(
        _ item: PhotosPickerItem,
        target: MediaConversionService.Target
    ) async -> ConversionSource? {
        let types = item.supportedContentTypes
        LogStore.log(
            "xdz.convert.source.begin target=\(target) item=\(item.itemIdentifier ?? "nil") types=\(types.map(\.identifier))"
        )
        switch target {
        case .livePhoto:
            if types.contains(where: { $0.conforms(to: .gif) }) {
                LogStore.log("xdz.convert.source.branch gif target=livePhoto")
                return await loadGIFConversionSource(item)
            }
            guard types.contains(where: { $0.conforms(to: .movie) }) else {
                LogStore.log("xdz.convert.source.reject target=livePhoto reason=notMovie")
                return nil
            }
            guard let source = await loadMovie(item: item) else {
                LogStore.log("xdz.convert.source.fail target=livePhoto reason=loadMovie")
                return nil
            }
            guard let conversionSource = source.conversionSource else {
                LogStore.log("xdz.convert.source.fail target=livePhoto reason=conversionSourceUnavailable")
                return nil
            }
            LogStore.log("xdz.convert.source.ready target=livePhoto ext=\(conversionSource.fileExtension) url=\(conversionSource.url.path)")
            return conversionSource

        case .video:
            if types.contains(where: { $0.conforms(to: .gif) }) {
                LogStore.log("xdz.convert.source.branch gif target=video")
                return await loadGIFConversionSource(item)
            }
            // playbackStyle(.imageAnimated) 也可能返回 APNG/动态 HEIC 等非 GIF 图片。
            // 这类素材没有 Live Photo 的 asset 标识，不能继续走 Live Photo 下载链路。
            guard types.contains(where: { $0.conforms(to: .movie) })
                || item.itemIdentifier != nil else {
                LogStore.log("xdz.convert.source.reject target=video reason=notLivePhotoOrGIF")
                return nil
            }
            // PhotosPicker 的 Live Photo 在不同系统版本、iCloud 状态下可能只返回
            // image/movie 或泛化的动态图片类型。入口已经完成筛选，这里直接尝试
            // 读取 Live Photo，避免因 supportedContentTypes 二次判断过严而提前失败。
            LogStore.log("xdz.convert.source.branch livePhoto target=video")
            guard let source = await loadLivePhoto(item: item, includingStillImage: false) else {
                LogStore.log("xdz.convert.source.fail target=video reason=loadLivePhoto types=\(types.map(\.identifier))")
                return nil
            }
            guard let conversionSource = source.conversionSource else {
                LogStore.log("xdz.convert.source.fail target=video reason=conversionSourceUnavailable")
                return nil
            }
            LogStore.log("xdz.convert.source.ready target=video ext=\(conversionSource.fileExtension) url=\(conversionSource.url.path)")
            return conversionSource
        }
    }

    private func loadGIFConversionSource(_ item: PhotosPickerItem) async -> ConversionSource? {
        LogStore.log("xdz.convert.gif.begin item=\(item.itemIdentifier ?? "nil")")
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            LogStore.log("xdz.convert.gif.fail reason=loadTransferable")
            return nil
        }
        LogStore.log("xdz.convert.gif.loaded bytes=\(data.count)")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFBloom-import-\(UUID().uuidString).gif")
        do {
            try data.write(to: url, options: .atomic)
            LogStore.log("xdz.convert.gif.ready url=\(url.path) bytes=\(data.count)")
            return ConversionSource(
                url: url,
                name: NSLocalizedString("GIF", comment: "GIF conversion source"),
                fileExtension: "gif",
                temporaryFileURLs: [url]
            )
        } catch {
            LogStore.log("xdz.convert.gif.fail reason=write error=\(error)")
            return nil
        }
    }

    private func conversionInputFailureMessage(
        for target: MediaConversionService.Target
    ) -> String {
        switch target {
        case .livePhoto:
            return NSLocalizedString(
                "转为 Live Photo 只支持 GIF 和视频；普通照片不会被处理。",
                comment: "Live Photo conversion input restriction"
            )
        case .video:
            return NSLocalizedString(
                "转为视频只支持 Live Photo 和 GIF，请重新选择动态素材。",
                comment: "Video conversion input restriction"
            )
        }
    }

    private func isVideoConversionSource(_ fileExtension: String) -> Bool {
        ["mov", "mp4", "m4v"].contains(
            fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
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

    /// 按所选算法进入对应流程：foreground 直接提取，Vision 先分析轨迹。
    private func extractVideoSource(
        url: URL,
        name: String,
        sourceStartTime: TimeInterval = 0,
        sourceEndTime: TimeInterval? = nil,
        stillOrientation: CGImagePropertyOrientation,
        stillURL: URL? = nil
    ) async -> SegmentedClip? {
        let algorithm = appState.segmentationAlgorithm

        // Algorithm 1: the original class-agnostic foreground path has no
        // person prompt or track-selection UI. It goes straight to extraction.
        if algorithm == .foreground {
            return await appState.startSegmenting(
                url: url,
                name: name,
                algorithm: .foreground,
                sourceStartTime: sourceStartTime,
                sourceEndTime: sourceEndTime,
                stillOrientation: stillOrientation
            )
        }

        // Vision begins with a representative-frame prompt and continues into
        // its existing multi-track selection sheet.
        let preview = await firstFrame(
            of: url,
            stillURL: stillURL,
            at: sourceStartTime
        )
        guard let preview else { return nil }
        let choice: SubjectRegionChoice? = await withCheckedContinuation { continuation in
            pendingSubjectRegionSelection = PendingSubjectRegionSelection(image: preview) { result in
                continuation.resume(returning: result.confirmed ? result : nil)
            }
        }
        guard let choice else { return nil }
        let initialRegion = choice.points

        guard let analysis = await appState.analyzeVideoSubjects(
            url: url,
            sourceStartTime: sourceStartTime,
            sourceEndTime: sourceEndTime,
            stillOrientation: stillOrientation,
            initialSelectionRegion: initialRegion
        ) else {
            return nil
        }

        guard !analysis.tracks.isEmpty else {
            if initialRegion != nil {
                appState.segmentationError = NSLocalizedString(
                    "圈选范围内没有识别到主体，请重新圈选。",
                    comment: "No subject inside the initial lasso"
                )
                return nil
            }
            return await appState.startSegmenting(
                url: url,
                name: name,
                sourceStartTime: sourceStartTime,
                sourceEndTime: sourceEndTime,
                stillOrientation: stillOrientation
            )
        }

        let selectedIDs: Set<Int>
        let selectionRegion: [CGPoint]?
        if analysis.tracks.count > 1 {
            let choice: (Set<Int>, [CGPoint]?)? = await withCheckedContinuation { (continuation: CheckedContinuation<(Set<Int>, [CGPoint]?)?, Never>) in
                // 预圈选来自分析起始帧，而选择器显示的代表帧可能是另一帧；
                // 不把旧坐标直接画到另一帧上，避免造成误导。
                pendingSubjectSelection = PendingSubjectSelection(
                    analysis: analysis,
                    initialRegion: nil,
                    debugRegion: initialRegion
                ) { selected, region in
                    guard let selected else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: (selected, region))
                }
            }
            guard let choice else {
                return nil
            }
            selectedIDs = choice.0
            selectionRegion = choice.1
        } else {
            selectedIDs = [analysis.tracks[0].id]
            selectionRegion = nil
        }

        guard !selectedIDs.isEmpty else { return nil }
        return await appState.startSegmenting(
            url: url,
            name: name,
            sourceStartTime: sourceStartTime,
            sourceEndTime: sourceEndTime,
            stillOrientation: stillOrientation,
            analysis: analysis,
            selectedSubjectIDs: selectedIDs,
            selectionRegion: selectionRegion ?? initialRegion
        )
    }

    /// Static-image UI flow for the selected algorithm.
    private func extractPhotoSource(cgImage: CGImage, name: String) async -> SegmentedClip? {
        let algorithm = appState.segmentationAlgorithm
        return await appState.startPhotoSegmenting(
            cgImage: cgImage,
            name: name,
            algorithm: algorithm
        )
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
                        let maxExtractionDuration = purchaseManager.allowedExtractionDuration(
                            configuredDuration: appState.maxExtractionDuration
                        )
                        let duration = await videoDuration(of: url)
                        // 所有动态素材都先让用户确认时间范围。即使源文件没有超过
                        // 最大时长，也需要让用户可以从中间开始截取，而不是默认从 0 秒开始。
                        let range: ClosedRange<TimeInterval>? = await withCheckedContinuation { continuation in
                            pendingVideoRange = PendingVideoRange(
                                url: url,
                                name: name,
                                duration: duration,
                                maxDuration: min(maxExtractionDuration, max(duration, 0.1)),
                                confirmTitle: "生成剪影"
                            ) { selectedRange in
                                continuation.resume(returning: selectedRange)
                            }
                        }
                        guard let range else { continue }
                        let extractedClip = await extractVideoSource(
                            url: url,
                            name: name,
                            sourceStartTime: range.lowerBound,
                            sourceEndTime: range.upperBound,
                            stillOrientation: stillOrientation,
                            stillURL: stillURL
                        )
                        if let extractedClip {
                            extractedCount += 1
                            lastExtractedClip = extractedClip
                        } else {
                            extractionFailures.append(appState.segmentationError ?? "video extraction failed")
                            failedSources.append(source)
                            failedKinds.append(kind)
                        }
                    case .static:
                        if let cgImage = await firstFrame(of: url, stillURL: stillURL) {
                            let extractedClip = await extractPhotoSource(cgImage: cgImage, name: name)
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
                    let extractedClip = await extractPhotoSource(cgImage: cgImage, name: name)
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
                let retryableURLs = Set(failedSources.flatMap(\.temporaryFileURLs))
                sources.forEach { $0.removeTemporaryFiles(except: retryableURLs) }
                lastImportedSources = failedSources
                lastImportedKinds = failedKinds
            } else {
                sources.forEach { $0.removeTemporaryFiles() }
                lastImportedSources.removeAll()
                lastImportedKinds.removeAll()
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
        lastImportedSources.forEach { $0.removeTemporaryFiles() }
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
    private struct ConversionSource {
        let url: URL
        let name: String
        let fileExtension: String
        let temporaryFileURLs: [URL]

        func removeTemporaryFiles() {
            for temporaryFileURL in temporaryFileURLs {
                try? FileManager.default.removeItem(at: temporaryFileURL)
            }
        }
    }

    private enum ImportSource {
        case video(url: URL, name: String, stillOrientation: CGImagePropertyOrientation, stillURL: URL?)
        case photo(cgImage: CGImage, name: String)

        var conversionSource: ConversionSource? {
            guard case .video(let url, let name, _, let stillURL) = self else { return nil }
            return ConversionSource(
                url: url,
                name: name,
                fileExtension: url.pathExtension.isEmpty ? "mov" : url.pathExtension,
                temporaryFileURLs: [url] + (stillURL.map { [$0] } ?? [])
            )
        }

        var temporaryFileURLs: [URL] {
            guard case .video(let url, _, _, let stillURL) = self else { return [] }
            return [url] + (stillURL.map { [$0] } ?? [])
        }

        func removeTemporaryFiles(except preservedURLs: Set<URL> = []) {
            for url in temporaryFileURLs where !preservedURLs.contains(url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
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

    private func loadLivePhoto(
        item: PhotosPickerItem,
        includingStillImage: Bool = true
    ) async -> ImportSource? {
        let progressHandler: @Sendable (Double) -> Void = { value in
            Task { @MainActor in self.downloadProgress = value }
        }
        guard let video = await PhotoLibraryMediaImporter.loadExtractionVideo(
            from: item,
            progress: progressHandler,
            includingStillImage: includingStillImage
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
    private func firstFrame(
        of videoURL: URL,
        stillURL: URL?,
        at time: TimeInterval = 0
    ) async -> CGImage? {
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
            let (image, _) = try await generator.image(
                at: CMTime(seconds: max(time, 0), preferredTimescale: 600)
            )
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
                    .lfAnimatedPlainButtonStyle()
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
                            .lfAnimatedPlainButtonStyle()
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
        let effectiveMaxDuration = purchaseManager.allowedExtractionDuration(
            configuredDuration: appState.maxExtractionDuration
        )
        return SectionCard(title: "正在生成剪影") {
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
                Text(appState.segmentingName.isEmpty
                    ? NSLocalizedString("正在准备剪影素材", comment: "Preparing cutout assets")
                    : appState.segmentingName)
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("本次最多处理 %1$lld 秒，超出部分从开头截取", comment: "Maximum extraction duration"),
                    Int64(effectiveMaxDuration)
                ))
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("取消生成", role: .cancel) {
                    importTask?.cancel()
                }
                .lfActionButtonStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("library-extraction-progress-cancel")
            }
        }
        .accessibilityIdentifier("library-extraction-progress")
    }

    private var conversionCard: some View {
        SectionCard(verbatimTitle: conversionTarget == .livePhoto
            ? NSLocalizedString("正在转换为 Live Photo", comment: "Live Photo conversion progress title")
            : NSLocalizedString("正在转换为视频", comment: "Video conversion progress title")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProgressView(value: conversionProgress)
                        .tint(LF.gold)
                    Text(String(format: "%d%%", Int(conversionProgress * 100)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                }
                Text(
                    conversionTitle.isEmpty
                        ? NSLocalizedString("正在准备转换", comment: "Preparing media conversion")
                        : conversionTitle
                )
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(NSLocalizedString("取消转换", comment: "Cancel media conversion"), role: .cancel) {
                    conversionTask?.cancel()
                }
                .lfActionButtonStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("library-conversion-progress-cancel")
            }
        }
        .accessibilityIdentifier("library-conversion-progress")
    }

    // MARK: - 素材概览

    private var clipsSection: some View {
        SectionCard(title: nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("最近添加")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LF.header)
                        .textCase(.uppercase)
                        .tracking(1.2)

                    Spacer(minLength: 8)

                    NavigationLink {
                        AllClipsView()
                    } label: {
                        HStack(spacing: 4) {
                            Text("全部素材")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LF.actionPrimary)
                    }
                    .accessibilityIdentifier("library-view-all-clips")
                }

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
                        ForEach(appState.clips.prefix(4)) { clip in
                            // 首页只展示最近四项，完整管理入口在独立素材页。
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

/// 完整素材浏览页，搜索和类型筛选固定在素材列表入口附近，避免首页随素材数量增长。
private struct AllClipsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var filter: ClipLibraryFilter = .all
    @State private var menuClip: SegmentedClip?
    @State private var clipDeletionAlert: ClipDeletionAlert?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private var visibleClips: [SegmentedClip] {
        let filtered = appState.clips.filter { filter.includes($0) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filtered }
        return filtered.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Picker("素材类型", selection: $filter) {
                    ForEach(ClipLibraryFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                SectionCard(title: nil) {
                    if visibleClips.isEmpty {
                        if appState.clips.isEmpty {
                            EmptyStateView(
                                icon: "folder",
                                title: "还没有素材",
                                message: "选择视频、Live Photo 或照片，\n自动生成透明剪影素材"
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        } else {
                            ContentUnavailableView(
                                "没有匹配的素材",
                                systemImage: "magnifyingglass",
                                description: Text("试试其他名称或筛选条件")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                    } else {
                        HStack {
                            Text("最近添加")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LF.header)
                                .textCase(.uppercase)
                                .tracking(1.2)
                            Spacer()
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("%1$lld items", comment: "Visible asset count"),
                                Int64(visibleClips.count)
                            ))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(LF.textSecondary)
                        }

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visibleClips) { clip in
                                ClipCell(
                                    clip: clip,
                                    onOpen: { menuClip = clip },
                                    onDelete: { requestClipDeletion(clip) },
                                    deleteAccessibilityLabel: "删除素材",
                                    deleteAccessibilityIdentifier: "library-all-delete-clip-\(clip.id)"
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .safeAreaPadding(.bottom, 24)
        .scrollIndicators(.hidden)
        .navigationTitle("全部素材")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索素材名称")
        .magicBackground()
        .fullScreenCover(item: $menuClip) { clip in
            ClipMenuView(
                clip: clip,
                onClose: { menuClip = nil }
            )
            .environmentObject(appState)
        }
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
        .accessibilityIdentifier("library-all-clips-page")
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

private enum ClipLibraryFilter: String, CaseIterable, Identifiable {
    case all
    case live
    case still

    var id: Self { self }

    var title: String {
        switch self {
        case .all: NSLocalizedString("全部", comment: "All clip filter")
        case .live: NSLocalizedString("动态", comment: "Animated clip filter")
        case .still: NSLocalizedString("静态", comment: "Still clip filter")
        }
    }

    func includes(_ clip: SegmentedClip) -> Bool {
        switch self {
        case .all: true
        case .live: clip.frameCount > 1
        case .still: clip.frameCount <= 1
        }
    }
}

/// 动态素材主体选择器。分析阶段完成后展示代表帧和轨迹框，支持选择一个或多个主体。
private struct SubjectSelectionView: View {
    let analysis: VideoSegmentationAnalysis
    let initialLassoPoints: [CGPoint]
    let debugLassoPoints: [CGPoint]
    let onCancel: () -> Void
    let onConfirm: (Set<Int>, [CGPoint]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<Int>

    private let colors: [Color] = [.cyan, .orange, .green, .pink, .purple, .yellow]
    @State private var isLassoMode = false
    @State private var lassoPoints: [CGPoint] = []
    @State private var isFrameInspectorPresented = false

    init(
        analysis: VideoSegmentationAnalysis,
        initialLassoPoints: [CGPoint] = [],
        debugLassoPoints: [CGPoint] = [],
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Set<Int>, [CGPoint]?) -> Void
    ) {
        self.analysis = analysis
        self.initialLassoPoints = initialLassoPoints
        self.debugLassoPoints = debugLassoPoints
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedIDs = State(initialValue: Set(analysis.tracks.map(\.id)))
        _lassoPoints = State(initialValue: initialLassoPoints)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("选择要保留的主体")
                            .font(.headline)
                        Text("可以选择一个或多个主体，未选择的主体不会进入素材。")
                            .font(.subheadline)
                            .foregroundStyle(LF.textSecondary)
                    }

                    subjectSelectionList

                    Button {
                        isFrameInspectorPresented = true
                    } label: {
                        Label("逐帧检查边界", systemImage: "film.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(analysis.frameDebug.isEmpty)
                    .accessibilityHint("查看每一帧的主体边界和圈选曲线")

                    if let previewImage = analysis.previewImage {
                        SubjectPreviewCanvas(
                            image: previewImage,
                            tracks: analysis.tracks,
                            selectedIDs: selectedIDs,
                            colors: colors,
                            onToggle: toggle,
                            isLassoMode: isLassoMode,
                            lassoPoints: $lassoPoints,
                            onLassoFinished: applyLasso
                        )

                        HStack(spacing: 10) {
                            Button {
                                isLassoMode.toggle()
                                if isLassoMode {
                                    lassoPoints = []
                                }
                            } label: {
                                Label(
                                    NSLocalizedString(isLassoMode ? "正在圈选" : "自由圈选", comment: "Lasso mode"),
                                    systemImage: isLassoMode ? "pencil.and.outline" : "lasso"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(isLassoMode ? LF.actionPrimary : LF.selectionFill)

                            if !lassoPoints.isEmpty {
                                Button("清除圈选") {
                                    lassoPoints = []
                                }
                                .buttonStyle(.bordered)
                            }

                            Spacer()
                        }
                        .font(.subheadline.weight(.medium))

                        Text(NSLocalizedString(
                            isLassoMode
                                ? "沿着要保留的主体画一圈，松手后会自动选中圈内主体。"
                                : "也可以使用自由圈选，或在上方列表中选择主体。",
                            comment: "Lasso instructions"
                        ))
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                    }

                }
                .padding(20)
            }
            .lfNavigationTitle("选择主体")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel("取消")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onConfirm(selectedIDs, lassoPoints.isEmpty ? nil : lassoPoints)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel("生成剪影")
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .magicBackground()
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(LF.background.opacity(0.94), for: .navigationBar)
            .onAppear {
                guard !initialLassoPoints.isEmpty else { return }
                applyLasso(initialLassoPoints)
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $isFrameInspectorPresented) {
            SubjectFrameInspectorView(
                frames: analysis.frameDebug,
                lassoPoints: lassoPoints.isEmpty ? debugLassoPoints : lassoPoints,
                selectedTrackIDs: selectedIDs
            )
        }
    }

    @ViewBuilder
    private var subjectSelectionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(analysis.tracks.enumerated()), id: \.element.id) { offset, track in
                Button {
                    toggle(track.id)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.black.opacity(0.08))
                            if let preview = track.previewImage {
                                Image(decorative: preview, scale: 1)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(4)
                            } else {
                                Image(systemName: "person.fill")
                                    .font(.caption)
                                    .foregroundStyle(colors[offset % colors.count])
                            }
                        }
                        .frame(width: 48, height: 60)
                        .overlay(alignment: .topTrailing) {
                            Text(subjectLabel(for: offset))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(colors[offset % colors.count], in: Capsule())
                                .offset(x: 5, y: -5)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("主体 %@", comment: "Subject label"),
                                subjectLabel(for: offset) as NSString
                            ))
                                .font(.subheadline.weight(.medium))
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("出现 %1$lld 帧 · 平均面积 %2$lld", comment: "Subject track summary"),
                                Int64(track.frameCount),
                                Int64(track.averageArea.rounded())
                            ))
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                        }
                        Spacer()
                        Image(systemName: selectedIDs.contains(track.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedIDs.contains(track.id) ? LF.actionPrimary : LF.textSecondary)
                            .font(.title3)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .lfAnimatedPlainButtonStyle()
                .accessibilityLabel(String.localizedStringWithFormat(
                    NSLocalizedString("主体 %@", comment: "Subject accessibility label"),
                    subjectLabel(for: offset) as NSString
                ))
                .accessibilityValue(NSLocalizedString(
                    selectedIDs.contains(track.id) ? "已选择" : "未选择",
                    comment: "Subject selection state"
                ))

                if offset < analysis.tracks.count - 1 {
                    Divider().overlay(LF.surface2.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 14)
        .background(LF.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        Text(String.localizedStringWithFormat(
            NSLocalizedString("已选择 %1$lld 个主体", comment: "Selected subject count"),
            Int64(selectedIDs.count)
        ))
            .font(.caption)
            .foregroundStyle(LF.textSecondary)
    }

    private func toggle(_ id: Int) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func subjectLabel(for offset: Int) -> String {
        guard offset < 26, let scalar = UnicodeScalar(65 + offset) else {
            return "\(offset + 1)"
        }
        return String(scalar)
    }

    private func applyLasso(_ points: [CGPoint]) {
        let matches = analysis.tracks.reduce(into: Set<Int>()) { result, track in
            if let preview = track.previewImage {
                let coverage = lassoCoverage(in: preview, polygon: points)
                let coverageText = String(format: "%.3f", coverage)
                LogStore.log(
                    "xdz.subject.lasso.coverage track=\(track.id) value=\(coverageText)"
                )
                if coverage >= 0.20 {
                    result.insert(track.id)
                }
                return
            }
            guard let box = selectionBounds(for: track) else { return }
            let corners = [
                CGPoint(x: box.minX, y: box.minY),
                CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY),
                CGPoint(x: box.minX, y: box.maxY)
            ]
            let center = CGPoint(x: box.midX, y: box.midY)
            if pointIsInsidePolygon(center, polygon: points)
                || corners.contains(where: { pointIsInsidePolygon($0, polygon: points) })
                || points.contains(where: { box.contains($0) }) {
                result.insert(track.id)
            }
        }

        guard !matches.isEmpty else {
            LogStore.log("xdz.subject.lasso.selected tracks=none")
            return
        }
        selectedIDs = matches
        isLassoMode = false
        LogStore.log("xdz.subject.lasso.selected tracks=\(matches.sorted().map(String.init).joined(separator: ","))")
    }

    private func lassoCoverage(in image: CGImage, polygon: [CGPoint]) -> Double {
        let sampleSize = 80
        let bytesPerRow = sampleSize * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * sampleSize)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleSize,
                height: sampleSize,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            return true
        }
        guard rendered else { return 0 }

        var visible = 0
        var inside = 0
        for y in 0..<sampleSize {
            let rowStart = y * bytesPerRow
            for x in 0..<sampleSize where pixels[rowStart + x * 4 + 3] > 24 {
                visible += 1
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(sampleSize),
                    y: 1 - (CGFloat(y) + 0.5) / CGFloat(sampleSize)
                )
                if pointIsInsidePolygon(point, polygon: polygon) {
                    inside += 1
                }
            }
        }
        guard visible > 0 else { return 0 }
        return Double(inside) / Double(visible)
    }

    /// Vision 在部分姿态下会返回接近全画布的包围盒。主体预览本身仍有
    /// alpha 信息，因此优先从预览图重新计算可见范围，避免圈选和标注误判。
    private func selectionBounds(for track: VideoSubjectTrack) -> CGRect? {
        if let preview = track.previewImage,
           let bounds = visibleBounds(in: preview) {
            return CGRect(
                x: bounds.minX / CGFloat(preview.width),
                y: 1 - bounds.maxY / CGFloat(preview.height),
                width: bounds.width / CGFloat(preview.width),
                height: bounds.height / CGFloat(preview.height)
            )
        }
        guard let box = track.previewBoundingBox, box.width * box.height < 0.9 else {
            return nil
        }
        return box
    }

    private func visibleBounds(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width where pixels[rowStart + x * 4 + 3] > 24 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func pointIsInsidePolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var isInside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let lhs = polygon[current]
            let rhs = polygon[previous]
            let crosses = (lhs.y > point.y) != (rhs.y > point.y)
            if crosses {
                let denominator = rhs.y - lhs.y
                let xAtY = denominator == 0
                    ? lhs.x
                    : (rhs.x - lhs.x) * (point.y - lhs.y) / denominator + lhs.x
                if point.x < xAtY {
                    isInside.toggle()
                }
            }
            previous = current
        }
        return isInside
    }
}

private struct SubjectFrameInspectorView: View {
    let frames: [VideoSegmentationFrameDebug]
    let lassoPoints: [CGPoint]
    let selectedTrackIDs: Set<Int>

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFrameIndex = 0

    private var selectedFrame: VideoSegmentationFrameDebug? {
        guard frames.indices.contains(selectedFrameIndex) else { return nil }
        return frames[selectedFrameIndex]
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let selectedFrame {
                    SubjectFrameBoundaryCanvas(
                        frame: selectedFrame,
                        lassoPoints: lassoPoints,
                        selectedTrackIDs: selectedTrackIDs
                    )
                    .frame(maxHeight: .infinity)

                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("第 %1$lld 帧 / 共 %2$lld 帧", comment: "Frame preview position"),
                        Int64(selectedFrame.id + 1),
                        Int64(frames.count)
                    ))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LF.textPrimary)

                    boundaryLegend

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(Array(frames.enumerated()), id: \.element.id) { offset, frame in
                                Button {
                                    selectedFrameIndex = offset
                                } label: {
                                    Image(decorative: frame.image, scale: 1)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 70, height: 88)
                                        .background(.black.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(
                                                    offset == selectedFrameIndex ? LF.actionPrimary : .clear,
                                                    lineWidth: 3
                                                )
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            Text("\(frame.id + 1)")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(.black.opacity(0.65), in: Capsule())
                                                .padding(4)
                                        }
                                }
                                .lfAnimatedPlainButtonStyle()
                                .accessibilityLabel(String.localizedStringWithFormat(
                                    NSLocalizedString("第 %1$lld 帧", comment: "Frame accessibility label"),
                                    Int64(frame.id + 1)
                                ))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    ContentUnavailableView(
                        "没有可检查的帧",
                        systemImage: "film",
                        description: Text("主体分析没有生成逐帧调试数据。")
                    )
                }
            }
            .padding(16)
            .navigationTitle("逐帧检查边界")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel("完成")
                }
            }
            .magicBackground()
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(LF.background.opacity(0.94), for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var boundaryLegend: some View {
        HStack(spacing: 14) {
            legendItem(color: .cyan, title: "已选主体")
            legendItem(color: .orange, title: "其他主体")
            legendItem(color: .yellow, title: "圈选曲线")
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(LF.textSecondary)
    }

    private func legendItem(color: Color, title: LocalizedStringKey) -> some View {
        Label {
            Text(title)
        } icon: {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }
}

private struct SubjectFrameBoundaryCanvas: View {
    let frame: VideoSegmentationFrameDebug
    let lassoPoints: [CGPoint]
    let selectedTrackIDs: Set<Int>

    var body: some View {
        GeometryReader { proxy in
            let rect = imageContentRect(for: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(.black.opacity(0.12))

                ForEach(frame.instanceContours.keys.sorted(), id: \.self) { instance in
                    if let contour = frame.instanceContours[instance], contour.count >= 3 {
                        let trackID = frame.instanceToTrack[instance]
                        let isSelected = trackID.map(selectedTrackIDs.contains) ?? false
                        Path { path in
                            let first = canvasPoint(for: contour[0], in: rect)
                            path.move(to: first)
                            for point in contour.dropFirst() {
                                path.addLine(to: canvasPoint(for: point, in: rect))
                            }
                            path.closeSubpath()
                        }
                        .stroke(
                            isSelected ? .cyan : .orange,
                            style: StrokeStyle(lineWidth: isSelected ? 3 : 2, lineJoin: .round)
                        )
                        .shadow(color: .black.opacity(0.65), radius: 2)

                        if let first = contour.first {
                            Text(trackID.map { "T\($0)" } ?? "I\(instance)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background((isSelected ? Color.cyan : Color.orange).opacity(0.9), in: Capsule())
                                .position(canvasPoint(for: first, in: rect))
                        }
                    }
                }

                if lassoPoints.count >= 3 {
                    Path { path in
                        let first = canvasPoint(for: lassoPoints[0], in: rect)
                        path.move(to: first)
                        for point in lassoPoints.dropFirst() {
                            path.addLine(to: canvasPoint(for: point, in: rect))
                        }
                        path.closeSubpath()
                    }
                    .stroke(
                        .yellow,
                        style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [7, 5])
                    )
                    .shadow(color: .black.opacity(0.7), radius: 2)
                }
            }
        }
        .aspectRatio(
            CGFloat(frame.image.width) / CGFloat(max(frame.image.height, 1)),
            contentMode: .fit
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LF.surface2, lineWidth: 1)
        }
    }

    private func imageContentRect(for size: CGSize) -> CGRect {
        let imageAspect = CGFloat(frame.image.width) / CGFloat(max(frame.image.height, 1))
        let containerAspect = size.width / max(size.height, 1)
        if imageAspect > containerAspect {
            let width = size.width
            let height = width / imageAspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: width, height: height)
        }
        let height = size.height
        let width = height * imageAspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    }

    private func canvasPoint(for point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
}

private struct SubjectPreviewCanvas: View {
    let image: CGImage
    let tracks: [VideoSubjectTrack]
    let selectedIDs: Set<Int>
    let colors: [Color]
    let onToggle: (Int) -> Void
    let isLassoMode: Bool
    @Binding var lassoPoints: [CGPoint]
    let onLassoFinished: ([CGPoint]) -> Void

    var body: some View {
        GeometryReader { proxy in
            let contentRect = imageContentRect(for: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(.black.opacity(0.12))

                if lassoPoints.count > 1 {
                    Path { path in
                        let first = canvasPoint(for: lassoPoints[0], in: contentRect)
                        path.move(to: first)
                        for point in lassoPoints.dropFirst() {
                            path.addLine(to: canvasPoint(for: point, in: contentRect))
                        }
                        if lassoPoints.count > 2 {
                            path.closeSubpath()
                        }
                    }
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .allowsHitTesting(false)
                }

                if isLassoMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard let point = normalizedPoint(value.location, in: contentRect) else { return }
                                    if let last = lassoPoints.last {
                                        let dx = point.x - last.x
                                        let dy = point.y - last.y
                                        guard dx * dx + dy * dy > 0.0004 else { return }
                                    }
                                    lassoPoints.append(point)
                                }
                                .onEnded { _ in
                                    guard lassoPoints.count >= 3 else { return }
                                    onLassoFinished(lassoPoints)
                                }
                        )
                }
            }
        }
        .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LF.surface2, lineWidth: 1)
        }
    }

    private func imageContentRect(for size: CGSize) -> CGRect {
        let imageAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let containerAspect = size.width / max(size.height, 1)
        if imageAspect > containerAspect {
            let width = size.width
            let height = width / imageAspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: width, height: height)
        }
        let height = size.height
        let width = height * imageAspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    }

    private func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width,
            y: (point.y - rect.minY) / rect.height
        )
    }

    private func canvasPoint(for point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height
        )
    }

    private func subjectLabel(for offset: Int) -> String {
        guard offset < 26, let scalar = UnicodeScalar(65 + offset) else {
            return "\(offset + 1)"
        }
        return String(scalar)
    }
}

/// Vision 的分析前圈选入口。
private struct InitialSubjectRegionPickerView: View {
    let image: CGImage
    let onCancel: () -> Void
    let onSkip: () -> Void
    let onConfirm: ([CGPoint]?) -> Void

    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VisionInitialRegionPickerView(
            image: image,
            onCancel: onCancel,
            onSkip: onSkip,
            onConfirm: { points in
                onConfirm(points.isEmpty ? nil : points)
            }
        )
    }
}

private struct VisionInitialRegionPickerView: View {
    let image: CGImage
    let onCancel: () -> Void
    let onSkip: () -> Void
    let onConfirm: ([CGPoint]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isLassoMode = true
    @State private var lassoPoints: [CGPoint] = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("先圈选主体范围")
                        .font(.headline)
                    Text("先圈出要保留的人物，分析时会用它缩小主体范围。")
                        .font(.subheadline)
                        .foregroundStyle(LF.textSecondary)
                }

                SubjectPreviewCanvas(
                    image: image,
                    tracks: [],
                    selectedIDs: [],
                    colors: [],
                    onToggle: { _ in },
                    isLassoMode: isLassoMode,
                    lassoPoints: $lassoPoints,
                    onLassoFinished: { points in
                        lassoPoints = points
                        isLassoMode = false
                    }
                )

                HStack(spacing: 10) {
                    Button {
                        isLassoMode = true
                        lassoPoints = []
                    } label: {
                        Label(
                            NSLocalizedString(isLassoMode ? "正在圈选" : "重新圈选", comment: "Lasso mode"),
                            systemImage: "lasso"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isLassoMode ? LF.actionPrimary : LF.selectionFill)

                    if !lassoPoints.isEmpty {
                        Button(NSLocalizedString("清除", comment: "Clear lasso")) {
                            lassoPoints = []
                            isLassoMode = true
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .font(.subheadline.weight(.medium))

                Spacer(minLength: 0)
            }
            .padding(20)
            .lfNavigationTitle("选择主体范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel("取消")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onConfirm(lassoPoints)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel("开始分析")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("跳过圈选") {
                        onSkip()
                        dismiss()
                    }
                }
            }
            .magicBackground()
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(LF.background.opacity(0.94), for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
private struct VideoRangePickerView: View {
    let url: URL
    let name: String
    let duration: TimeInterval
    let maxDuration: TimeInterval
    let confirmTitle: LocalizedStringKey
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
        confirmTitle: LocalizedStringKey = "生成剪影",
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ClosedRange<TimeInterval>) -> Void
    ) {
        let safeDuration = max(duration, 0.1)
        let safeMaxDuration = max(maxDuration, 0.1)
        self.url = url
        self.name = name
        self.duration = safeDuration
        self.maxDuration = safeMaxDuration
        self.confirmTitle = confirmTitle
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
                            NSLocalizedString(
                                previewController.isPlaying ? "停止预览" : "预览选中片段",
                                comment: "Preview selected segment"
                            ),
                            systemImage: previewController.isPlaying ? "stop.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .lfActionButtonStyle(.primary)
                }
                .padding(20)
            }
            .lfNavigationTitle("视频范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel("取消")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onConfirm(startTime...endTime)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel(confirmTitle)
                }
            }
            .magicBackground()
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(LF.background.opacity(0.94), for: .navigationBar)
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
            var images: [CGImage] = []
            images.reserveCapacity(count)
            for index in 0..<count {
                let progress = Double(index) / Double(max(count - 1, 1))
                let time = CMTime(
                    seconds: requestedDuration * progress,
                    preferredTimescale: 600
                )
                if let image = await withCheckedContinuation({ continuation in
                    generator.generateCGImageAsynchronously(for: time) { image, _, _ in
                        continuation.resume(returning: image)
                    }
                }) {
                    images.append(image)
                }
            }
            return images
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
    @State private var isPreparingPlayback = false

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
                    isPlaying: $isPlaying,
                    isPreparingPlayback: $isPreparingPlayback
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
                    Group {
                        if isPreparingPlayback {
                            ClipPreviewLoadingIndicator()
                        } else {
                            ClipPreviewBadgeIcon(
                                systemName: isPlaying ? "pause.fill" : "play.fill",
                                foregroundStyle: LF.actionPrimary,
                                backgroundStyle: LF.actionPrimary.opacity(0.16)
                            )
                        }
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if clip.loadAudioURL() != nil {
                    ClipPreviewBadgeIcon(
                        systemName: "waveform",
                        foregroundStyle: LF.actionPrimary,
                        backgroundStyle: LF.actionPrimary.opacity(0.16)
                    )
                    .frame(width: 44, height: 44)
                }
            }
            .overlay(alignment: .topLeading) {
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .lfCircleIconButtonStyle(
                        diameter: 26,
                        iconSize: 11,
                        foregroundColor: LF.header,
                        backgroundColor: LF.header.opacity(0.16)
                    )
                    .accessibilityLabel(deleteAccessibilityLabel)
                    .accessibilityIdentifier(deleteAccessibilityIdentifier)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !clip.excludedFrames.isEmpty {
                    ClipPreviewBadgeIcon(
                        systemName: "square.grid.3x3",
                        foregroundStyle: LF.header,
                        backgroundStyle: LF.header.opacity(0.16)
                    )
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("已修改帧")
                } else if clip.edgeStyle != .none {
                    ClipPreviewBadgeIcon(
                        systemName: "square.dashed",
                        foregroundStyle: LF.header,
                        backgroundStyle: LF.header.opacity(0.16)
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
    let stickerComposition: Composition
    @Binding var isPlaying: Bool
    let watermark: ExportWatermark?
    let onCrop: () -> Void
    let onRotateCounterclockwise: () -> Void
    let onRotateClockwise: () -> Void
    @State private var watermarkFrame: CGImage?
    @State private var isPreparingPlayback = false

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
                isPlaying: $isPlaying,
                isPreparingPlayback: $isPreparingPlayback,
                usesCoreStickerStylePreview: true,
                coreStickerStyleComposition: stickerComposition
            )
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let watermark, let watermarkFrame {
                        GeometryReader { geometry in
                            let targetWidth = min(geometry.size.width, geometry.size.height) * 0.48
                            Image(decorative: watermarkFrame, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(width: targetWidth)
                                .opacity(watermark.opacity)
                                .padding(.trailing, geometry.size.width * 0.10)
                                .padding(.bottom, geometry.size.height * 0.10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }

            if clip.frameCount > 1 {
                ClipPreviewPlayButton(
                    clip: clip,
                    isPlaying: $isPlaying,
                    isPreparingPlayback: $isPreparingPlayback
                )
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
        .task(id: watermark?.decorationID) {
            guard let decorationID = watermark?.decorationID else {
                watermarkFrame = nil
                return
            }
            watermarkFrame = DecorationRenderer().previewImage(for: decorationID)
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
        .lfAnimatedPlainButtonStyle()
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
    @State private var isPreparingPlayback = false

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
                        isPlaying: $isPlaying,
                        isPreparingPlayback: $isPreparingPlayback
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
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel("取消")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
                        onFinish(draftRect == full ? nil : draftRect)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel("完成")
                }
            }
            .magicBackground()
        }
    }
}

/// 素材详情页：单击素材后进入，集中处理原始预览、帧编辑和导出。
struct ClipMenuView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var purchaseManager: PurchaseManager
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
    @State private var showProStore = false
    @State private var renameText = ""
    @State private var isExportingGIF = false
    @State private var exportGIFError: String?
    @State private var exportGIFTask: Task<Void, Never>?
    @State private var isSavingSticker = false
    @State private var saveStickerError: String?
    @State private var saveStickerTask: Task<Void, Never>?
    @State private var didSaveSticker = false
    @State private var clipExportState = ClipExportState()
    @State private var gifPresets: [GIFExportPreset] = []
    @State private var gifResolution: ExportResolution = .p720
    @State private var gifFPS = 15.0
    @State private var isEstimatingGIF = false
    @State private var previewWatermark: ExportWatermark?
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

    private var isStaticSticker: Bool {
        currentClip.frameCount <= 1
    }

    /// 贴纸详情页没有编辑器里的真实元素，因此用当前素材构造一个最小预览工程，
    /// 复用编辑器和导出共用的贴纸效果选择器与渲染管线。
    private var stickerPreviewElement: CompositionElement {
        let frameDuration = 1 / max(currentClip.fps, 1)
        let duration = max(currentClip.effectiveDuration, frameDuration)
        return CompositionElement(
            kind: .clip(clipID: currentClip.id),
            name: currentClip.name,
            transform: ElementTransform(
                position: CGPoint(
                    x: CGFloat(max(currentClip.renderedWidth, 1)) / 2,
                    y: CGFloat(max(currentClip.renderedHeight, 1)) / 2
                )
            ),
            endTime: duration,
            sourceEndTime: max(currentClip.duration, frameDuration)
        )
    }

    private var stickerPreviewComposition: Composition {
        Composition(
            name: currentClip.name,
            canvas: CanvasSpec(
                width: CGFloat(max(currentClip.renderedWidth, 1)),
                height: CGFloat(max(currentClip.renderedHeight, 1))
            ),
            duration: max(currentClip.effectiveDuration, 1 / max(currentClip.fps, 1)),
            fps: max(currentClip.fps, 1),
            elements: [stickerPreviewElement],
            background: .clear
        )
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
        .sheet(isPresented: $showProStore) {
            GIFBloomProStoreView()
        }
        .onAppear {
            previewWatermark = purchaseManager.hasPro ? nil : DecorationRenderer.randomLogoWatermark()
        }
        .onChange(of: purchaseManager.hasPro) { _, hasPro in
            previewWatermark = hasPro ? nil : DecorationRenderer.randomLogoWatermark()
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
            Text(exportGIFError ?? NSLocalizedString("请稍后重试。", comment: "Retry message"))
        }
        .alert("保存贴纸失败", isPresented: Binding(
            get: { saveStickerError != nil },
            set: { if !$0 { saveStickerError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveStickerError ?? NSLocalizedString("请稍后重试。", comment: "Retry message"))
        }
        .onDisappear {
            exportGIFTask?.cancel()
            saveStickerTask?.cancel()
        }
        .task(id: "\(currentClip.id)-\(currentClip.rotationQuarterTurns)-\(currentClip.cropCacheKey)-\(previewWatermarkID)") {
            guard !isStaticSticker else { return }
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
                    stickerComposition: stickerPreviewComposition,
                    isPlaying: $isPlayingPreview,
                    watermark: previewWatermark,
                    onCrop: beginClipCrop,
                    onRotateCounterclockwise: { rotateClip(clockwise: false) },
                    onRotateClockwise: { rotateClip(clockwise: true) }
                )
                if !purchaseManager.hasPro {
                    WatermarkNoticeCard {
                        showProStore = true
                    }
                }
                stickerEffectSection
                if !isStaticSticker {
                    gifExportSection
                } else {
                    stickerSaveSection
                }
                // 帧选择入口暂时隐藏；保留 frameEditorButton、sheet 状态和 FrameGridView，后续可恢复。
                // frameEditorButton
            }
            .padding(20)
        }
    }

    private var stickerEffectSection: some View {
        SectionCard(title: "贴纸效果") {
            StickerStyleOptionPicker(
                clip: currentClip,
                element: stickerPreviewElement,
                composition: stickerPreviewComposition,
                currentTime: 0,
                selectedStyle: currentClip.stickerStyle
            ) { style in
                appState.setClipStickerStyle(currentClip.id, style)
            }
        }
    }

    private var stickerSaveSection: some View {
        SectionCard(title: "导出") {
            Button {
                saveStickerToPhotos()
            } label: {
                Label(
                    isSavingSticker ? "保存中…" : "保存到相册",
                    systemImage: isSavingSticker ? "hourglass" : "photo.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .lfActionButtonStyle(isSavingSticker ? .secondary : .primary)
            .disabled(isSavingSticker)

            if didSaveSticker {
                Label("贴纸已保存到相册。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(LF.selectionText)
            }
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
                            NSLocalizedString(
                                isExportingGIF ? "取消导出" : "保存到相册",
                                comment: "GIF export action"
                            ),
                            systemImage: isExportingGIF ? "xmark" : "photo.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .lfActionButtonStyle(isExportingGIF ? .secondary : .primary)
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
        let watermark = purchaseManager.hasPro ? nil : (previewWatermark ?? DecorationRenderer.randomLogoWatermark())
        previewWatermark = watermark
        exportGIFTask = Task(priority: .userInitiated) { @MainActor in
            defer {
                isExportingGIF = false
                exportGIFTask = nil
            }
            do {
                _ = try await appState.exportClipAsTransparentGIF(
                    clipID,
                    resolution: gifResolution,
                    fps: gifFPS,
                    watermark: watermark
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

    private func saveStickerToPhotos() {
        guard !isSavingSticker else { return }
        saveStickerError = nil
        didSaveSticker = false
        isSavingSticker = true
        let clipID = clip.id
        let watermark = purchaseManager.hasPro ? nil : (previewWatermark ?? DecorationRenderer.randomLogoWatermark())
        previewWatermark = watermark
        saveStickerTask = Task { @MainActor in
            defer {
                isSavingSticker = false
                saveStickerTask = nil
            }
            do {
                try await appState.exportClipAsStickerPNG(clipID, watermark: watermark)
                didSaveSticker = true
            } catch is CancellationError {
                // 用户离开详情页时主动取消，不显示错误。
            } catch {
                saveStickerError = error.localizedDescription
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

    private var previewWatermarkID: String {
        previewWatermark?.decorationID ?? "no-watermark"
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
                fpsOptions: fpsOptions,
                watermark: purchaseManager.hasPro ? nil : previewWatermark
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
            .lfAnimatedPlainButtonStyle()
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
        .lfAnimatedPlainButtonStyle()
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
