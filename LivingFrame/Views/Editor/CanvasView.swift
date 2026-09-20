import LivingFrameCore
import SwiftUI

/// 画布预览：CI 逐帧渲染 + 直接操作（点选 / 拖动 / 双指缩放 / 旋转 / 选中框）
struct CanvasView: View {
    @EnvironmentObject private var appState: AppState
    /// 只有编辑页主画布驱动播放；全屏预览只负责显示，避免两个画布同时推进时间。
    private let drivesPlayback: Bool
    @State private var previewImage: UIImage?
    @State private var viewportSize: CGSize = .zero
    /// 预览渲染器：按视口尺寸解码/渲染，不改变导出分辨率
    @State private var renderer = CompositionRenderer(frameMaxPixelSize: 900)
    /// 手势起始快照（拖动/缩放/旋转共用）
    @State private var gestureStartTransforms: [UUID: ElementTransform] = [:]
    /// 背景图片手势起始快照：背景元素的拖动/缩放作用于遮罩内取景。
    @State private var gestureStartBackgroundSettings: [UUID: BackgroundElementSettings] = [:]
    /// 背景取景交互状态，用于提示用户当前正在移动还是缩放图片。
    @State private var backgroundGestureKind: BackgroundGestureKind?
    @State private var isBackgroundInteracting = false
    /// 画布直接操作期间使用轻量预览；松手后恢复高质量合成。
    @State private var isCanvasManipulating = false
    /// 拖动普通素材时，把未选中内容与选中内容临时分层，避免整张合成图异步刷新造成素材滞后。
    @State private var isLiveDragPreview = false
    /// 直接操作期间只在预览副本中临时抬高当前素材；不会修改工程里的 zIndex。
    @State private var temporarilyElevatedElementIDs: Set<UUID> = []
    @State private var interactiveBaseImage: UIImage?
    @State private var interactiveSelectionImage: UIImage?
    @State private var interactiveDragTranslation: CGSize = .zero
    @State private var interactivePreviewToken = 0
    @State private var clearInteractivePreviewAfterRender = false
    /// 背景取景期间只合成一次其它图层，当前背景用 SwiftUI 直接变换，保证手指与图片 1:1 跟随。
    @State private var interactiveBackgroundBaseImage: UIImage?
    @State private var interactiveBackgroundFrame: CGImage?
    @State private var interactiveBackgroundElementID: UUID?
    @State private var backgroundPreviewToken = 0
    /// 双指手势活跃中（防止同时触发拖动）
    @State private var isPinching = false
    /// 同一区域内多个素材完全重叠时，连续点击同一位置可以依次选中下层素材。
    /// 这是画布上唯一能在没有可见边缘时访问下层图片的交互入口。
    @State private var overlapSelectionAnchor: CGPoint?
    @State private var overlapSelectionIDs: [UUID] = []
    @State private var overlapSelectionIndex = 0
    /// 缩放与旋转共享一组双指输入，但一旦确认意图就锁定模式，避免捏合时被微小角度变化带偏。
    @State private var transformGestureMode: TransformGestureMode?
    /// 裁剪模式下的临时裁剪框（画布坐标系）
    @State private var cropRect: CGRect?
    /// 渲染版本号：异步渲染完成时只有最新版本才写入，避免旧帧覆盖新帧。
    @State private var renderVersion = 0
    /// 是否有一个预览渲染正在执行；执行期间只保留最新请求，避免任务堆积或全部被跳过。
    @State private var isRenderInFlight = false
    /// 背景分区预览直接采用导出的最终输出路径，避免降采样阶段混合透明遮罩。
    @State private var usesExactBackgroundPreview = false
    /// CI 渲染串行执行，避免多个元素同时渲染造成任务积压和结果互相覆盖。
    private static let renderQueue = DispatchQueue(
        label: "com.livingframe.canvas-render",
        qos: .userInteractive
    )

    private enum TransformGestureMode: Equatable {
        case scaling
        case rotating
    }

    private let magnificationIntentThreshold: CGFloat = 0.02
    private let rotationIntentThreshold: CGFloat = 0.08

    /// 双击画布素材时由编辑页打开检查器；全屏预览不传回调，因此保持只读预览。
    private let onRequestInspector: () -> Void
    /// 选中框左上角的删除入口；全屏预览不传回调，因此不显示编辑操作。
    private let onDeleteSelection: () -> Void
    /// 拼接器的预览模式只渲染画面，不显示选中框，也不接收编辑手势。
    private let allowsInteraction: Bool

    init(
        drivesPlayback: Bool = true,
        allowsInteraction: Bool = true,
        onRequestInspector: @escaping () -> Void = {},
        onDeleteSelection: @escaping () -> Void = {}
    ) {
        self.drivesPlayback = drivesPlayback
        self.allowsInteraction = allowsInteraction
        self.onRequestInspector = onRequestInspector
        self.onDeleteSelection = onDeleteSelection
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if isBackgroundInteracting,
                   let interactiveBackgroundBaseImage,
                   let interactiveBackgroundFrame,
                   let interactiveBackgroundElementID,
                   let interactiveBackgroundElement = appState.composition?.elements.first(where: {
                       $0.id == interactiveBackgroundElementID
                   }),
                   let composition = appState.composition,
                   isCollageBackgroundElement(interactiveBackgroundElement) {
                    Image(uiImage: interactiveBackgroundBaseImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                    InteractiveBackgroundImageLayer(
                        frame: interactiveBackgroundFrame,
                        canvasSize: composition.canvasRect.size,
                        settings: interactiveBackgroundElement.backgroundSettings ?? BackgroundElementSettings()
                    )
                } else if isLiveDragPreview,
                   let interactiveBaseImage,
                   let interactiveSelectionImage {
                    Image(uiImage: interactiveBaseImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                    Image(uiImage: interactiveSelectionImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .offset(interactiveDragTranslation)
                } else if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Color.black
                }
                if allowsInteraction {
                    if appState.isCropping {
                        cropOverlay
                    } else {
                        selectionOverlay
                        backgroundInteractionOverlay
                    }
                }
            }
            .background {
                if appState.composition?.background.kind == .clear {
                    CheckerboardView()
                }
            }
            .aspectRatio(canvasAspect, contentMode: .fit)
            // 画布使用“嵌入式纸面”层次：靠细边框和极弱环境阴影区分背景，
            // 避免明显下坠阴影让画布像一张悬浮卡片。
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(LF.brandTint.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.045), radius: 16, x: 0, y: 4)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            viewportSize = geo.size
                            refreshRendererScale()
                        }
                        .onChange(of: geo.size) { _, newValue in
                            viewportSize = newValue
                            refreshRendererScale()
                        }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                handleDoubleTap(at: location)
            }
            .onTapGesture { location in
                handleTap(at: location)
            }
            // 裁剪模式下由裁剪框/手柄独占拖动；普通编辑模式才让画布拖动优先，
            // 避免外层拖动手势抢走裁剪框的触摸事件。
            .highPriorityGesture(
                dragGesture,
                including: appState.isCropping ? .none : .all
            )
            .simultaneousGesture(magnifyGesture)
            .simultaneousGesture(rotateGesture)
            .allowsHitTesting(allowsInteraction)

            if allowsInteraction, appState.isCropping {
                cropToolbar
            }
        }
        .onAppear {
            refreshRendererScale()
            render()
        }
        .onChange(of: appState.composition) { _, _ in
            // 时间轴移动/裁剪只影响某个时间点是否可见，不值得在每一个触摸事件
            // 重做整张 CI 合成。拖拽结束时由 isTimelineEditing 的变化补一次最终预览。
            guard !appState.isTimelineEditing,
                  (!appState.isCanvasEditing || isCanvasManipulating),
                  !isBackgroundInteracting else { return }
            // 普通拖动已经有“底图 + 当前素材”的轻量分层预览，避免同时启动整张合成。
            if isLiveDragPreview { return }
            if usesExactBackgroundPreview != needsExactBackgroundPreview {
                refreshRendererScale()
            }
            render()
        }
        .onChange(of: appState.isTimelineEditing) { _, isEditing in
            if !isEditing {
                refreshRendererScale()
                render()
            }
        }
        .onChange(of: appState.isCanvasEditing) { _, isEditing in
            if !isEditing {
                refreshRendererScale()
                render()
            }
        }
        .onChange(of: appState.currentTime) { _, _ in
            render()
        }
        .onChange(of: appState.isPlaying) { _, playing in
            if playing {
                render()
            }
        }
        .onChange(of: appState.isReversed) { _, _ in
            refreshRendererScale()
            render()
        }
        .onChange(of: appState.clipStyleVersion) { _, _ in
            // 分区蒙版会改变 CI 的渲染图。重建预览 renderer，避免在已有其它素材时
            // 复用旧的 Core Image 中间结果，造成要等到删/改其它素材才显示新分区。
            refreshRendererScale()
            render()
        }
        .onChange(of: appState.isCropping) { _, cropping in
            if cropping {
                cropRect = appState.composition.map(initialCropRect(for:))
                refreshRendererScale()
                render()
            } else {
                refreshRendererScale()
                render()
            }
        }
    }

    private func initialCropRect(for comp: Composition) -> CGRect {
        if let existing = comp.cropRect {
            return existing.intersection(comp.canvasRect)
        }

        // 第一次进入裁剪时预留少量边距，让用户既能向内缩小，也能向外放大。
        let inset = min(min(comp.canvas.width, comp.canvas.height) * 0.08, 120)
        return comp.canvasRect.insetBy(dx: inset, dy: inset)
    }

    private var canvasAspect: CGFloat {
        guard let comp = appState.composition else { return 9 / 16 }
        // 进入裁剪模式只增加裁剪框，不改变编辑器原有的画布布局尺寸。
        // 裁剪框仍以完整画布坐标绘制，最终输出由 composition.renderRect 决定。
        let rect = comp.renderRect
        return rect.width / rect.height
    }

    // MARK: - 点选

    private func handleTap(at location: CGPoint) {
        guard let comp = appState.composition, !appState.isCropping else { return }
        let geometry = viewportGeometry(for: comp)
        let time = appState.currentTime
        // 从顶层往下命中（忽略不可见元素）。同一点有多个候选时，连续点击会循环选中。
        let candidates = comp.elements
            .sorted { $0.zIndex > $1.zIndex }
            .filter { element in
                if case .canvasEdge = element.kind { return false }
                if isCollageChild(element, in: comp) { return false }
                guard element.isVisible(at: time) else { return false }
                return rotatedHitTest(
                    element: element,
                    in: comp,
                    geometry: geometry,
                    point: location,
                    time: time
                )
            }
        if candidates.isEmpty {
            resetOverlapSelectionCycle()
            // 点空白处 = 选中背景对象（检查器可编辑背景纯色/图案）
            appState.selectBackground()
            return
        }

        let candidateIDs = candidates.map(\.id)
        let isSameOverlapPoint = overlapSelectionAnchor.map {
            hypot($0.x - location.x, $0.y - location.y) <= 18
        } ?? false
        if isSameOverlapPoint, overlapSelectionIDs == candidateIDs {
            overlapSelectionIndex = (overlapSelectionIndex + 1) % candidates.count
        } else {
            overlapSelectionAnchor = location
            overlapSelectionIDs = candidateIDs
            overlapSelectionIndex = 0
        }
        appState.selectElement(candidates[overlapSelectionIndex].id)
    }

    private func resetOverlapSelectionCycle() {
        overlapSelectionAnchor = nil
        overlapSelectionIDs.removeAll()
        overlapSelectionIndex = 0
    }

    /// 双击先按同一套命中测试选中素材，再打开检查器；点到空白处不会误弹检查器。
    private func handleDoubleTap(at location: CGPoint) {
        guard !appState.isCropping else { return }
        handleTap(at: location)
        guard appState.primarySelectedElement != nil else { return }
        onRequestInspector()
    }

    /// 旋转变换后的点-元素命中测试
    private func rotatedHitTest(
        element: CompositionElement,
        in comp: Composition,
        geometry: ViewportGeometry,
        point: CGPoint,
        time: TimeInterval
    ) -> Bool {
        let frame = elementFrame(element, in: comp, geometry: geometry, at: time)
        // 分区背景虽然使用整张画布尺寸生成图像，但画布中只有当前分区实际可见。
        // 命中测试必须同时满足分区遮罩和图片实际取景范围，否则点击空白分区
        // 会错误选中上层背景，同一区域内多张图片也无法按位置区分。
        if isCollageBackgroundElement(element) {
            let settings = element.backgroundSettings ?? BackgroundElementSettings()
            let isInsidePartition = BackgroundPartitionShape(settings: settings)
                .path(in: frame)
                .cgPath
                .contains(point)
            guard isInsidePartition else { return false }
            return backgroundImageBounds(
                for: element,
                in: comp,
                geometry: geometry,
                at: time
            )?.contains(point) ?? true
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let rotation = renderer.resolvedTransform(for: element, in: comp, at: time).rotation
        if rotation == 0 {
            return frame.contains(point)
        }
        // 把点击点反向绕中心旋转，再测试轴对称矩形
        let dx = point.x - center.x
        let dy = point.y - center.y
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let localX = dx * cosR + dy * sinR
        let localY = -dx * sinR + dy * cosR
        return abs(localX) <= frame.width / 2 && abs(localY) <= frame.height / 2
    }

    /// 背景素材在画布上的实际取景范围，与拼接编辑器的 imageBounds 保持一致。
    /// 背景元素本身的 frame 是整张画布，真正可点击的范围还会受到素材原始比例、
    /// cropScale、cropOffset 和 90° 旋转影响。
    private func backgroundImageBounds(
        for element: CompositionElement,
        in comp: Composition,
        geometry: ViewportGeometry,
        at time: TimeInterval
    ) -> CGRect? {
        guard case .background(let backgroundID) = element.kind else { return nil }
        let media = appState.backgroundMedia.first(where: { $0.id == backgroundID })
            ?? BackgroundStore.shared.media(named: backgroundID)
        let sourceSize: CGSize
        if let media, media.width > 0, media.height > 0 {
            sourceSize = CGSize(width: media.width, height: media.height)
        } else if let frame = BackgroundStore.shared.loadFrame(named: backgroundID, at: time) {
            sourceSize = CGSize(width: frame.width, height: frame.height)
        } else {
            return nil
        }

        // geometry.rect 使用画布坐标；命中点使用视口坐标，先还原成画布在视口中的实际矩形，
        // 这样画布上下/左右留白时，图片命中范围仍与屏幕显示位置一致。
        let rect = CGRect(
            x: geometry.offsetX,
            y: geometry.offsetY,
            width: geometry.rect.width * geometry.scale,
            height: geometry.rect.height * geometry.scale
        )
        let fillScale = max(
            rect.width / max(sourceSize.width, 1),
            rect.height / max(sourceSize.height, 1)
        )
        var size = CGSize(
            width: sourceSize.width * fillScale,
            height: sourceSize.height * fillScale
        )
        let settings = element.backgroundSettings ?? BackgroundElementSettings()
        let turns = ((settings.rotationQuarterTurns % 4) + 4) % 4
        if turns % 2 == 1 {
            size = CGSize(width: size.height, height: size.width)
        }
        let rotationScale = turns % 2 == 1
            ? max(rect.width / max(rect.height, 1), rect.height / max(rect.width, 1))
            : 1
        size.width *= rotationScale * settings.cropScale
        size.height *= rotationScale * settings.cropScale

        let center = CGPoint(
            x: rect.midX + settings.cropOffset.x * rect.width / max(comp.canvasRect.width, 1),
            y: rect.midY - settings.cropOffset.y * rect.height / max(comp.canvasRect.height, 1)
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - 拖动（移动全部选中素材）

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !appState.isCropping,
                      !appState.selectedElementIDs.isEmpty,
                      !isPinching,
                      let comp = appState.composition else { return }
                let scale = canvasToViewportScale(comp)
                if gestureStartTransforms.isEmpty {
                    snapshotTransforms(comp)
                    beginCanvasManipulation()
                    prepareInteractiveDragPreview(comp)
                }
                guard let snaps = gestureStartTransforms.snapshot else { return }
                interactiveDragTranslation = value.translation
                if selectedBackgroundElement != nil {
                    beginBackgroundInteraction(.moving)
                }
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                for id in appState.selectedElementIDs {
                    guard let start = snaps[id] else { continue }
                    guard let element = comp.elements.first(where: { $0.id == id }) else { continue }
                    if isCollageBackgroundElement(element),
                       let backgroundStart = gestureStartBackgroundSettings[id] {
                        appState.setBackgroundCropOffset(
                            id,
                            CGPoint(
                                x: backgroundStart.cropOffset.x + dx,
                                y: backgroundStart.cropOffset.y - dy
                            )
                        )
                    } else if case .canvasEdge = element.kind {
                        continue
                    } else {
                        appState.updateElement(id) { element in
                            element.transform.position = CGPoint(
                                x: start.position.x + dx,
                                y: start.position.y - dy
                            )
                        }
                    }
                }
            }
            .onEnded { _ in
                clearInteractivePreviewAfterRender = isLiveDragPreview
                gestureStartTransforms = [:]
                gestureStartBackgroundSettings = [:]
                endCanvasManipulation()
            }
    }

    // MARK: - 双指缩放（缩放全部选中素材）

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard !appState.isCropping,
                      !appState.selectedElementIDs.isEmpty,
                      transformGestureMode != .rotating else { return }
                if transformGestureMode == nil {
                    guard abs(value - 1) >= magnificationIntentThreshold else { return }
                    transformGestureMode = .scaling
                }
                isPinching = true
                beginCanvasManipulation()
                if selectedBackgroundElement != nil {
                    beginBackgroundInteraction(.scaling)
                }
                if gestureStartTransforms.isEmpty {
                    snapshotTransforms(appState.composition)
                }
                guard let snaps = gestureStartTransforms.snapshot else { return }
                for id in appState.selectedElementIDs {
                    guard let start = snaps[id] else { continue }
                    guard let element = appState.composition?.elements.first(where: { $0.id == id }) else { continue }
                    if isCollageBackgroundElement(element),
                       let backgroundStart = gestureStartBackgroundSettings[id] {
                        appState.setBackgroundCropScale(
                            id,
                            backgroundStart.cropScale * value
                        )
                    } else if case .canvasEdge = element.kind {
                        continue
                    } else {
                        appState.updateElement(id) { element in
                            element.transform.scale = max(0.1, min(10, start.scale * value))
                        }
                    }
                }
            }
            .onEnded { _ in
                guard transformGestureMode == .scaling else { return }
                finishTransformGesture()
            }
    }

    // MARK: - 旋转（旋转全部选中素材）

    private var rotateGesture: some Gesture {
        RotationGesture()
            .onChanged { value in
                guard !appState.isCropping,
                      !appState.selectedElementIDs.isEmpty,
                      transformGestureMode != .scaling else { return }
                if transformGestureMode == nil {
                    // 双指捏合时允许少量自然抖动，但必须有明确的扭转意图才进入旋转模式。
                    guard abs(value.radians) >= rotationIntentThreshold else { return }
                    transformGestureMode = .rotating
                }
                isPinching = true
                beginCanvasManipulation()
                if gestureStartTransforms.isEmpty {
                    snapshotTransforms(appState.composition)
                }
                guard let snaps = gestureStartTransforms.snapshot else { return }
                let rawDelta = -Double(value.radians)
                // 以第一个可旋转素材作为组的参考方向，避免多选旋转时每个素材
                // 分别吸附到不同角度而破坏它们之间的相对关系。
                let referenceStart = snaps
                    .filter { id, _ in
                        guard let element = appState.composition?.elements.first(where: { $0.id == id }) else {
                            return false
                        }
                        if isCollageBackgroundElement(element) { return false }
                        if case .canvasEdge = element.kind { return false }
                        return true
                    }
                    .sorted { $0.key.uuidString < $1.key.uuidString }
                    .first?
                    .value
                let snappedDelta = referenceStart.map {
                    RotationSnapPolicy.snapped($0.rotation + rawDelta) - $0.rotation
                } ?? rawDelta
                for id in appState.selectedElementIDs {
                    guard let start = snaps[id] else { continue }
                    if let element = appState.composition?.elements.first(where: { $0.id == id }) {
                        if isCollageBackgroundElement(element) { continue }
                        if case .canvasEdge = element.kind { continue }
                    }
                    appState.updateElement(id) { element in
                        // RotationGesture 正值=顺时针（屏幕 y 向下），画布 y 向上需取反
                        element.transform.rotation = start.rotation + snappedDelta
                    }
                }
            }
            .onEnded { _ in
                guard transformGestureMode == .rotating else { return }
                finishTransformGesture()
            }
    }

    private func finishTransformGesture() {
        gestureStartTransforms = [:]
        gestureStartBackgroundSettings = [:]
        transformGestureMode = nil
        isPinching = false
        endCanvasManipulation()
    }

    private func snapshotTransforms(_ comp: Composition?) {
        guard let comp else { return }
        var snaps: [UUID: ElementTransform] = [:]
        for id in appState.selectedElementIDs {
            if let element = comp.elements.first(where: { $0.id == id }) {
                if case .canvasEdge = element.kind { continue }
                snaps[id] = element.transform
                if isCollageBackgroundElement(element) {
                    gestureStartBackgroundSettings[id] = element.backgroundSettings ?? BackgroundElementSettings()
                }
            }
        }
        gestureStartTransforms = snaps
    }

    /// 为普通素材建立一次性的分层预览：底层保留其它内容，上层只包含当前选中素材。
    /// 拖动期间上层直接用 SwiftUI 位移，松手后再切回完整 CI 合成。
    private func prepareInteractiveDragPreview(_ comp: Composition) {
        let selectedIDs = appState.selectedElementIDs
        let selectedElements = comp.elements.filter { selectedIDs.contains($0.id) }
        guard !selectedElements.isEmpty,
              selectedElements.allSatisfy({ element in
                  if isCollageBackgroundElement(element) { return false }
                  if case .canvasEdge = element.kind { return false }
                  return true
              }) else {
            isLiveDragPreview = false
            return
        }

        let selectedCollageGroupIDs = Set(selectedElements.compactMap { element -> UUID? in
            if case .collage(let groupID) = element.kind { return groupID }
            return nil
        })
        let selectedCollageChildIDs = Set(comp.elements.compactMap { element -> UUID? in
            guard case .background = element.kind,
                  let groupID = element.collageGroupID,
                  selectedCollageGroupIDs.contains(groupID) else { return nil }
            return element.id
        })

        var baseComposition = comp
        baseComposition.elements.removeAll {
            selectedIDs.contains($0.id) || selectedCollageChildIDs.contains($0.id)
        }

        var selectionComposition = comp
        selectionComposition.elements = selectedElements + comp.elements.filter {
            selectedCollageChildIDs.contains($0.id) && !selectedIDs.contains($0.id)
        }
        selectionComposition = compositionWithInteractionElevation(selectionComposition)
        selectionComposition.background = .clear
        selectionComposition.audioClips.removeAll()

        interactivePreviewToken &+= 1
        let token = interactivePreviewToken
        isLiveDragPreview = true
        interactiveBaseImage = nil
        interactiveSelectionImage = nil
        interactiveDragTranslation = .zero
        clearInteractivePreviewAfterRender = false

        let time = min(appState.currentTime, comp.duration)
        let previewRenderer = CompositionRenderer(
            frameMaxPixelSize: 720,
            isPlaybackReversed: appState.isReversed
        )
        Self.renderQueue.async { [baseComposition, selectionComposition, previewRenderer, time] in
            let baseCG = previewRenderer.render(baseComposition, at: time)
            let selectionCG = previewRenderer.render(selectionComposition, at: time)
            let baseImage = baseCG.map(UIImage.init(cgImage:))
            let selectionImage = selectionCG.map(UIImage.init(cgImage:))
            DispatchQueue.main.async {
                guard self.interactivePreviewToken == token,
                      self.isLiveDragPreview else { return }
                self.interactiveBaseImage = baseImage
                self.interactiveSelectionImage = selectionImage
            }
        }
    }

    private func clearInteractiveDragPreview() {
        interactivePreviewToken &+= 1
        isLiveDragPreview = false
        interactiveBaseImage = nil
        interactiveSelectionImage = nil
        interactiveDragTranslation = .zero
        clearInteractivePreviewAfterRender = false
    }

    // MARK: - 选中框

    private var selectionOverlay: some View {
        GeometryReader { geo in
            ZStack {
                let geometry = viewportGeometry(for: appState.composition, viewport: geo.size)
                ForEach(selectedElements.filter { element in
                    if case .canvasEdge = element.kind { return false }
                    return true
                }) { element in
                    let frame = elementFrame(
                        element,
                        in: appState.composition,
                        geometry: geometry,
                        at: appState.currentTime,
                        usesVisibleStickerBounds: true
                    )
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    // 画布 rotation 正值=逆时针；SwiftUI rotationEffect 屏幕坐标系正值=顺时针，需取反
                    let effectiveTransform = appState.composition.map {
                        renderer.resolvedTransform(for: element, in: $0, at: appState.currentTime)
                    } ?? element.transform
                    let rotation = -effectiveTransform.rotation
                    let isBackground = isCollageBackgroundElement(element)
                    ZStack {
                        SelectionBorderShape(cornerGap: 26)
                            .stroke(
                                LF.header.opacity(0.75),
                                style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: [6, 4])
                            )
                            .shadow(color: LF.header.opacity(0.12), radius: 2)
                            .allowsHitTesting(false)

                        if selectedElements.count == 1,
                           !isBackground,
                           allowsInteraction,
                           !appState.isCropping {
                            selectionActionButtons(for: element)
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .rotationEffect(.radians(rotation))
                    .position(center)
                }
            }
        }
    }

    /// 单选素材的操作按钮跟随选中外框定位，避免按钮与画布固定角落脱节。
    /// 四个角共用缩略图上的圆形图标按钮样式，保持尺寸、主题色和按压反馈一致。
    private func selectionActionButtons(for element: CompositionElement) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                selectionCornerButton(
                    systemName: "trash",
                    accessibilityLabel: "删除素材",
                    foregroundColor: LF.destructive,
                    backgroundColor: LF.destructive.opacity(0.16),
                    action: onDeleteSelection
                )
                .offset(x: -22, y: -22)
            }
            .overlay(alignment: .topTrailing) {
                selectionCornerButton(
                    systemName: "pencil.line",
                    accessibilityLabel: "编辑",
                    accessibilityIdentifier: "editor-canvas-adjust",
                    foregroundColor: LF.actionPrimary,
                    backgroundColor: LF.actionPrimary.opacity(0.16),
                    action: onRequestInspector
                )
                .offset(x: 22, y: -22)
            }
            .overlay(alignment: .bottomLeading) {
                selectionCornerButton(
                    systemName: "square.3.layers.3d.top.filled",
                    accessibilityLabel: "上移图层",
                    accessibilityIdentifier: "editor-canvas-layer-up",
                    foregroundColor: LF.actionPrimary,
                    backgroundColor: LF.actionPrimary.opacity(0.16)
                ) {
                    appState.moveElementZ(element.id, up: true)
                }
                .offset(x: -22, y: 22)
            }
            .overlay(alignment: .bottomTrailing) {
                selectionCornerButton(
                    systemName: "square.3.layers.3d.bottom.filled",
                    accessibilityLabel: "下移图层",
                    accessibilityIdentifier: "editor-canvas-layer-down",
                    foregroundColor: LF.actionPrimary,
                    backgroundColor: LF.actionPrimary.opacity(0.16)
                ) {
                    appState.moveElementZ(element.id, up: false)
                }
                .offset(x: 22, y: 22)
            }
    }

    private func selectionCornerButton(
        systemName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String? = nil,
        foregroundColor: Color,
        backgroundColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .lfCircleIconButtonStyle(
            diameter: 26,
            iconSize: 15,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private func isCollageBackgroundElement(_ element: CompositionElement) -> Bool {
        guard case .background = element.kind else { return false }
        return element.collageGroupID != nil
    }

    private func isCollageChild(_ element: CompositionElement, in composition: Composition) -> Bool {
        guard let groupID = element.collageGroupID,
              case .background = element.kind else { return false }
        return composition.elements.contains {
            if case .collage(let collageID) = $0.kind { return collageID == groupID }
            return false
        }
    }

    private var selectedElements: [CompositionElement] {
        guard let comp = appState.composition else { return [] }
        return comp.elements.filter { element in
            guard appState.selectedElementIDs.contains(element.id) else { return false }
            if case .canvasEdge = element.kind { return false }
            if isCollageChild(element, in: comp) { return false }
            return true
        }
    }

    private var selectedBackgroundElement: CompositionElement? {
        guard appState.selectedElementIDs.count == 1,
              let id = appState.selectedElementIDs.first,
              let element = appState.composition?.elements.first(where: { $0.id == id }),
              isCollageBackgroundElement(element) else { return nil }
        return element
    }

    private var backgroundInteractionOverlay: some View {
        GeometryReader { geo in
            if let element = selectedBackgroundElement,
               let comp = appState.composition {
                let geometry = viewportGeometry(for: comp, viewport: geo.size)
                let frame = elementFrame(element, in: comp, geometry: geometry, at: appState.currentTime)
                let settings = element.backgroundSettings ?? BackgroundElementSettings()
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            backgroundGestureKind == nil ? LF.header.opacity(0.9) : LF.gold,
                            style: StrokeStyle(lineWidth: 2, dash: [9, 6])
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    VStack {
                        HStack(spacing: 7) {
                            Image(systemName: backgroundGestureKind == .scaling ? "arrow.up.left.and.arrow.down.right" : "hand.draw")
                            Text(verbatim: backgroundGestureKind?.title ?? NSLocalizedString("背景取景", comment: "Canvas background framing"))
                            Text("· 拖动移动 · 双指缩放")
                                .foregroundStyle(.white.opacity(0.78))
                            Text(String(format: "%.1f×", settings.cropScale))
                                .monospacedDigit()
                                .foregroundStyle(LF.gold)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.72), in: Capsule())
                        Spacer()
                    }
                    .padding(.top, 10)
                }
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }

    private func beginBackgroundInteraction(_ kind: BackgroundGestureKind) {
        if backgroundGestureKind != kind {
            backgroundGestureKind = kind
            if !isBackgroundInteracting {
                isBackgroundInteracting = true
                if let comp = appState.composition {
                    prepareInteractiveBackgroundPreview(comp)
                }
                beginCanvasManipulation()
            }
        }
    }

    private func beginCanvasManipulation() {
        guard !isCanvasManipulating else { return }
        temporarilyElevatedElementIDs = appState.selectedElementIDs
        isCanvasManipulating = true
        appState.beginCanvasEdit()
        refreshRendererScale()
    }

    private func endCanvasManipulation() {
        guard isCanvasManipulating || isBackgroundInteracting || backgroundGestureKind != nil else { return }
        backgroundGestureKind = nil
        isBackgroundInteracting = false
        isCanvasManipulating = false
        backgroundPreviewToken &+= 1
        interactiveBackgroundBaseImage = nil
        interactiveBackgroundFrame = nil
        interactiveBackgroundElementID = nil
        temporarilyElevatedElementIDs.removeAll()
        appState.finishCanvasEdit()
        refreshRendererScale()
        render()
    }

    /// 为直接操作生成只用于预览的图层顺序：当前素材及其拼接容器放到最上方，
    /// 保留被选素材之间的原始相对顺序。这个副本不会回写到 AppState。
    private func compositionWithInteractionElevation(_ composition: Composition) -> Composition {
        guard !temporarilyElevatedElementIDs.isEmpty else { return composition }

        var elevated = composition
        var targetIDs = temporarilyElevatedElementIDs

        // 选中拼接子素材时，需要把外层拼接容器一起抬高，否则容器仍可能被其它
        // 普通图层遮住；子素材自身的 zIndex 仍用于保持拼接组内部顺序。
        for element in composition.elements where targetIDs.contains(element.id) {
            guard let groupID = element.collageGroupID else { continue }
            if let container = composition.elements.first(where: { candidate in
                if case .collage(let collageID) = candidate.kind {
                    return collageID == groupID
                }
                return false
            }) {
                targetIDs.insert(container.id)
            }
        }

        let targetIndices = elevated.elements.indices.filter { index in
            guard targetIDs.contains(elevated.elements[index].id) else { return false }
            if case .canvasEdge = elevated.elements[index].kind { return false }
            return true
        }.sorted {
            let lhs = elevated.elements[$0]
            let rhs = elevated.elements[$1]
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return $0 < $1
        }
        guard !targetIndices.isEmpty else { return composition }

        // 画布边框仍保持自己的相对层级；临时置顶只在普通内容之间生效，
        // 避免操作素材时把内容错误地盖到边框上面。
        let highestZIndex = elevated.elements
            .filter { element in
                if case .canvasEdge = element.kind { return false }
                return true
            }
            .map(\.zIndex)
            .max() ?? 0
        for (offset, index) in targetIndices.enumerated() {
            elevated.elements[index].zIndex = highestZIndex + 1 + offset
        }
        return elevated
    }

    /// 背景拖动/缩放期间不等待整张高质量合成：底层其它内容只渲染一次，选中背景直接作为图层变换。
    private func prepareInteractiveBackgroundPreview(_ comp: Composition) {
        guard let element = selectedBackgroundElement,
              case .background(let backgroundID) = element.kind else { return }

        backgroundPreviewToken &+= 1
        let token = backgroundPreviewToken
        let time = min(appState.currentTime, comp.duration)
        interactiveBackgroundElementID = element.id
        interactiveBackgroundFrame = nil
        interactiveBackgroundBaseImage = nil

        var baseComposition = comp
        baseComposition.elements.removeAll { $0.id == element.id }
        baseComposition = compositionWithInteractionElevation(baseComposition)
        let previewRenderer = CompositionRenderer(
            frameMaxPixelSize: 720,
            isPlaybackReversed: appState.isReversed
        )
        Self.renderQueue.async { [baseComposition, previewRenderer, time, backgroundID] in
            let frame = BackgroundStore.shared.loadFrame(named: backgroundID, at: time)
            let baseImage = previewRenderer.render(baseComposition, at: time).map(UIImage.init(cgImage:))
            DispatchQueue.main.async {
                guard self.backgroundPreviewToken == token,
                      self.isBackgroundInteracting else { return }
                self.interactiveBackgroundFrame = frame
                self.interactiveBackgroundBaseImage = baseImage
            }
        }
    }

    private func cornerPoints(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }

    // MARK: - 裁剪

    private var cropToolbar: some View {
        HStack(spacing: 10) {
            Button("取消") {
                appState.isCropping = false
            }
            .lfActionButtonStyle(.secondary)
            Button("重置") {
                cropRect = appState.composition?.canvasRect
            }
            .lfActionButtonStyle(.secondary)
            Button("完成") {
                if let cropRect {
                    appState.setCropRect(cropRect)
                }
                appState.isCropping = false
            }
            .lfActionButtonStyle(.primary)
        }
    }

    /// 裁剪框叠加层：外部压暗 + 九宫格 + 可移动/缩放的矩形裁剪框。
    private var cropOverlay: some View {
        Group {
            if let comp = appState.composition {
                CropOverlayView(
                    contentRect: comp.canvasRect,
                    minimumCropSize: 50,
                    cropRect: Binding(
                        get: { cropRect },
                        set: { cropRect = $0 }
                    )
                )
            }
        }
    }

    // MARK: - 坐标换算

    /// 视口显示的区域（裁剪后），元素坐标按该区域映射到屏幕
    private func viewportGeometry(
        for comp: Composition?,
        contentRect: CGRect? = nil,
        viewport: CGSize? = nil
    ) -> ViewportGeometry {
        let currentViewport = viewport ?? viewportSize
        guard let comp, currentViewport.width > 0, currentViewport.height > 0 else {
            return ViewportGeometry(scale: 1, offsetX: 0, offsetY: 0, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let rect = contentRect ?? comp.renderRect
        let aspect = rect.width / rect.height
        let displayWidth = min(currentViewport.width, currentViewport.height * aspect)
        let displayHeight = displayWidth / aspect
        return ViewportGeometry(
            scale: displayWidth / rect.width,
            offsetX: (currentViewport.width - displayWidth) / 2,
            offsetY: (currentViewport.height - displayHeight) / 2,
            rect: rect
        )
    }

    private func canvasToViewportScale(_ comp: Composition) -> CGFloat {
        viewportGeometry(for: comp).scale
    }

    /// 元素在视口中的框（画布坐标 → 视口，y 翻转；忽略旋转用于命中与框选）
    private func elementFrame(
        _ element: CompositionElement,
        in comp: Composition?,
        geometry: ViewportGeometry,
        at time: TimeInterval,
        usesVisibleStickerBounds: Bool = false
    ) -> CGRect {
        guard let comp else { return .zero }
        // 拼接背景由渲染器先生成完整画布尺寸的蒙版图，且背景取景只修改
        // cropOffset/cropScale，不使用 element.transform。独立照片走普通素材
        // 路径，直接根据图片尺寸和 element.transform 计算选中框。
        if isCollageBackgroundElement(element) {
            let canvasCenter = CGPoint(x: comp.canvasRect.midX, y: comp.canvasRect.midY)
            return ElementFrameGeometry.frame(
                contentSize: comp.canvasRect.size,
                transform: ElementTransform(position: canvasCenter),
                contentRect: geometry.rect,
                viewportScale: geometry.scale,
                viewportOffset: CGPoint(x: geometry.offsetX, y: geometry.offsetY)
            )
        }
        let size = elementContentSize(element, in: comp, at: time)
        let transform = renderer.resolvedTransform(for: element, in: comp, at: time)
        let fullContentBounds = CGRect(origin: .zero, size: size)
        let visibleContentBounds: CGRect
        if usesVisibleStickerBounds {
            visibleContentBounds = renderer.stickerSelectionBounds(for: element)
                .map { $0.intersection(fullContentBounds) }
                .flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
                ?? fullContentBounds
        } else {
            visibleContentBounds = fullContentBounds
        }
        let imageCenterOffset = CGPoint(
            x: visibleContentBounds.midX - size.width / 2,
            y: visibleContentBounds.midY - size.height / 2
        )
        let scaledOffset = CGPoint(
            x: imageCenterOffset.x * transform.scale,
            y: imageCenterOffset.y * transform.scale
        )
        let cosine = cos(transform.rotation)
        let sine = sin(transform.rotation)
        let visibleCenterOffset = CGPoint(
            x: scaledOffset.x * cosine - scaledOffset.y * sine,
            y: scaledOffset.x * sine + scaledOffset.y * cosine
        )
        let visibleTransform = ElementTransform(
            position: CGPoint(
                x: transform.position.x + visibleCenterOffset.x,
                y: transform.position.y + visibleCenterOffset.y
            ),
            scale: transform.scale,
            rotation: transform.rotation
        )
        return ElementFrameGeometry.frame(
            contentSize: visibleContentBounds.size,
            transform: visibleTransform,
            contentRect: geometry.rect,
            viewportScale: geometry.scale,
            viewportOffset: CGPoint(x: geometry.offsetX, y: geometry.offsetY)
        )
    }

    /// 选中框直接读取渲染器实际生成的内容矩形，避免 clip、文字、贴纸和特效
    /// 各自估算一套尺寸。素材不可用时返回零框，等素材恢复后会随预览刷新。
    private func elementContentSize(
        _ element: CompositionElement,
        in comp: Composition,
        at time: TimeInterval
    ) -> CGSize {
        // 不要依赖 FrameCache 的瞬时注册状态。AppState 是编辑器当前工程的
        // 稳定素材来源；选中框要和渲染器实际生成的素材矩形保持一致。
        if case .clip(let clipID) = element.kind,
           let clip = appState.clips.first(where: { $0.id == clipID }) {
            return CGSize(width: max(clip.renderedWidth, 1), height: max(clip.renderedHeight, 1))
        }
        if isCollageBackgroundElement(element) {
            return comp.canvasRect.size
        }
        return renderer.contentSize(for: element, in: comp, at: time) ?? .zero
    }

    // MARK: - 渲染

    /// 视口尺寸变化时重建预览渲染器（按屏幕像素渲染，预览清晰度足够且不浪费）
    private func refreshRendererScale() {
        let requiresExactOutput = needsExactBackgroundPreview
        usesExactBackgroundPreview = requiresExactOutput
        let pixelScale = UIScreen.main.scale
        // 编辑预览不需要按 Retina 全分辨率渲染；多素材同时播放时，
        // 把中间合成限制在 900px 内，避免渲染队列长期追不上播放时钟。
        let viewportMax = max(viewportSize.width, viewportSize.height)
        let maxPixel = viewportMax > 0
            ? min(viewportMax * pixelScale * 1.1, isCanvasManipulating ? 480 : 900)
            : 900
        renderer = CompositionRenderer(
            // 多张背景元素在画布中以透明遮罩相互拼接。预览若再对整图做 CI 仿射
            // 降采样，边缘会因透明像素混合而显示到错误分区；导出不走该分支。
            // 这里改为与导出相同的最终 CGImage 输出，确保所见即所得。
            frameMaxPixelSize: requiresExactOutput ? nil : maxPixel,
            isPlaybackReversed: appState.isReversed
        )
    }

    private var needsExactBackgroundPreview: Bool {
        guard let elements = appState.composition?.elements else { return false }
        let backgrounds = elements.compactMap { element -> BackgroundElementSettings? in
            guard isCollageBackgroundElement(element) else { return nil }
            return element.backgroundSettings ?? BackgroundElementSettings()
        }
        // 分区遮罩必须与最终输出使用同一像素尺寸。单张背景也不能走预览降采样，
        // 否则 CI 的透明遮罩在缩放后可能出现分区边界错位；普通整幅背景仍保留降采样。
        return backgrounds.contains { !$0.dividerLines.isEmpty } || backgrounds.count > 1
    }

    private func render() {
        renderVersion &+= 1

        guard !isRenderInFlight else { return }
        isRenderInFlight = true

        let version = renderVersion
        let composition = appState.composition.map { composition in
            var previewComposition = composition
            if appState.isCropping {
                previewComposition.cropRect = nil
            }
            return compositionWithInteractionElevation(previewComposition)
        }
        let time = composition.map { min(appState.currentTime, $0.duration) } ?? 0
        let renderer = renderer
        let renderStartedAt = Date()
        Self.renderQueue.async { [renderer, composition, time, renderStartedAt] in
            let cg = composition.flatMap {
                renderer.render($0, at: time)
            }
            DispatchQueue.main.async {
                self.isRenderInFlight = false

                let isCurrentVersion = version == self.renderVersion
                if let cg, isCurrentVersion {
                    self.previewImage = UIImage(cgImage: cg)
                } else if isCurrentVersion {
                    self.previewImage = nil
                }

                if isCurrentVersion, self.clearInteractivePreviewAfterRender {
                    self.clearInteractiveDragPreview()
                }

                // 播放期间如果有新时间点到达，当前渲染结束后立刻补渲染最新请求。
                if !isCurrentVersion {
                    self.render()
                } else if self.appState.isPlaying && self.drivesPlayback {
                    self.scheduleNextPlaybackStep(
                        renderDuration: Date().timeIntervalSince(renderStartedAt)
                    )
                }
            }
        }
    }

    /// 渲染完成后再推进播放时间，确保播放时钟不会领先于完整合成画面。
    private func scheduleNextPlaybackStep(renderDuration: TimeInterval) {
        guard let composition = appState.composition else { return }
        let targetFPS = min(max(composition.fps, 15), 30)
        let frameInterval = 1 / targetFPS
        let delay = max(0, frameInterval - renderDuration)
        let delta = max(frameInterval, renderDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.appState.isPlaying else { return }
            self.appState.tick(delta: delta)
        }
    }
}

/// 背景取景的轻量交互层。它只对原始帧做 SwiftUI 变换，不参与每个触摸采样点的 CI 合成。
private struct InteractiveBackgroundImageLayer: View {
    let frame: CGImage
    let canvasSize: CGSize
    let settings: BackgroundElementSettings

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Image(decorative: frame, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(Double(settings.rotationQuarterTurns * 90)))
                .scaleEffect(rotationFillScale(in: size))
                .scaleEffect(settings.cropScale)
                .offset(
                    x: settings.cropOffset.x * size.width / max(canvasSize.width, 1),
                    y: -settings.cropOffset.y * size.height / max(canvasSize.height, 1)
                )
                .clipped()
                .clipShape(BackgroundPartitionShape(settings: settings))
        }
        .allowsHitTesting(false)
    }

    private func rotationFillScale(in size: CGSize) -> CGFloat {
        let turns = ((settings.rotationQuarterTurns % 4) + 4) % 4
        guard turns % 2 == 1 else { return 1 }
        return max(size.width / max(size.height, 1), size.height / max(size.width, 1))
    }
}

/// 选中框的四条边各自绘制，四角为圆形操作按钮预留完整空位。
private struct SelectionBorderShape: Shape {
    let cornerGap: CGFloat

    func path(in rect: CGRect) -> Path {
        let gap = min(cornerGap, min(rect.width, rect.height) / 2)
        var path = Path()

        path.move(to: CGPoint(x: gap, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - gap, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX, y: gap))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - gap))

        path.move(to: CGPoint(x: rect.maxX - gap, y: rect.maxY))
        path.addLine(to: CGPoint(x: gap, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - gap))
        path.addLine(to: CGPoint(x: rect.minX, y: gap))

        return path
    }
}

private struct ViewportGeometry {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    /// 视口当前显示的区域（画布坐标系，裁剪后）
    let rect: CGRect
}

private enum BackgroundGestureKind: Equatable {
    case moving
    case scaling

    var title: String {
        switch self {
        case .moving: NSLocalizedString("正在移动背景", comment: "Background gesture")
        case .scaling: NSLocalizedString("正在缩放背景", comment: "Background gesture")
        }
    }
}

private extension Dictionary where Key == UUID, Value == ElementTransform {
    /// 起始快照副本（手势期间不被后续更新覆盖）
    var snapshot: [UUID: ElementTransform]? {
        isEmpty ? nil : self
    }
}
