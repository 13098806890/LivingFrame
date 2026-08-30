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
    @State private var interactiveBaseImage: UIImage?
    @State private var interactiveSelectionImage: UIImage?
    @State private var interactiveDragTranslation: CGSize = .zero
    @State private var interactivePreviewToken = 0
    @State private var clearInteractivePreviewAfterRender = false
    /// 双指手势活跃中（防止同时触发拖动）
    @State private var isPinching = false
    /// 裁剪模式下的临时裁剪框（画布坐标系）
    @State private var cropRect: CGRect?
    /// 当前裁剪手势的起始矩形；所有位移都基于同一快照，避免拖动过程中累计误差。
    @State private var cropGestureStartRect: CGRect?
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

    init(drivesPlayback: Bool = true) {
        self.drivesPlayback = drivesPlayback
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if isLiveDragPreview,
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
                if appState.isCropping {
                    cropOverlay
                } else {
                    selectionOverlay
                    backgroundInteractionOverlay
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
            .onTapGesture { location in
                handleTap(at: location)
            }
            .simultaneousGesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .simultaneousGesture(rotateGesture)

            if appState.isCropping {
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
            guard !appState.isTimelineEditing else { return }
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
                cropGestureStartRect = nil
                refreshRendererScale()
                render()
            } else {
                cropGestureStartRect = nil
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
        let rect = appState.isCropping ? comp.canvasRect : comp.renderRect
        return rect.width / rect.height
    }

    // MARK: - 点选

    private func handleTap(at location: CGPoint) {
        guard let comp = appState.composition, !appState.isCropping else { return }
        let geometry = viewportGeometry(for: comp)
        let time = appState.currentTime
        // 从顶层往下命中（忽略不可见元素）
        let hit = comp.elements
            .sorted { $0.zIndex > $1.zIndex }
            .first { element in
                if case .canvasEdge = element.kind { return false }
                guard element.isVisible(at: time) else { return false }
                return rotatedHitTest(element: element, in: comp, geometry: geometry, at: location)
            }
        if let hit {
            appState.selectElement(hit.id)
        } else {
            // 点空白处 = 选中背景对象（检查器可编辑背景纯色/图案）
            appState.selectBackground()
        }
    }

    /// 旋转变换后的点-元素命中测试
    private func rotatedHitTest(element: CompositionElement, in comp: Composition, geometry: ViewportGeometry, at point: CGPoint) -> Bool {
        let frame = elementFrame(element, in: comp, geometry: geometry)
        // 分区背景虽然使用整张画布尺寸生成图像，但画布中只有当前分区实际可见。
        // 命中测试必须使用同一遮罩路径，否则点击空白分区会错误选中上层背景。
        if case .background = element.kind {
            let settings = element.backgroundSettings ?? BackgroundElementSettings()
            return BackgroundPartitionShape(settings: settings)
                .path(in: frame)
                .cgPath
                .contains(point)
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let rotation = element.transform.rotation
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
                    if case .background = element.kind,
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
                guard !appState.isCropping, !appState.selectedElementIDs.isEmpty else { return }
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
                    if case .background = element.kind,
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
                gestureStartTransforms = [:]
                gestureStartBackgroundSettings = [:]
                isPinching = false
                endCanvasManipulation()
            }
    }

    // MARK: - 旋转（旋转全部选中素材）

    private var rotateGesture: some Gesture {
        RotationGesture()
            .onChanged { value in
                guard !appState.isCropping, !appState.selectedElementIDs.isEmpty else { return }
                isPinching = true
                beginCanvasManipulation()
                if gestureStartTransforms.isEmpty {
                    snapshotTransforms(appState.composition)
                }
                guard let snaps = gestureStartTransforms.snapshot else { return }
                for id in appState.selectedElementIDs {
                    guard let start = snaps[id] else { continue }
                    if let element = appState.composition?.elements.first(where: { $0.id == id }) {
                        if case .background = element.kind { continue }
                        if case .canvasEdge = element.kind { continue }
                    }
                    appState.updateElement(id) { element in
                        // RotationGesture 正值=顺时针（屏幕 y 向下），画布 y 向上需取反
                        element.transform.rotation = start.rotation - Double(value.radians)
                    }
                }
            }
            .onEnded { _ in
                gestureStartTransforms = [:]
                gestureStartBackgroundSettings = [:]
                isPinching = false
                endCanvasManipulation()
            }
    }

    private func snapshotTransforms(_ comp: Composition?) {
        guard let comp else { return }
        var snaps: [UUID: ElementTransform] = [:]
        for id in appState.selectedElementIDs {
            if let element = comp.elements.first(where: { $0.id == id }) {
                if case .canvasEdge = element.kind { continue }
                snaps[id] = element.transform
                if case .background = element.kind {
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
                  if case .background = element.kind { return false }
                  if case .canvasEdge = element.kind { return false }
                  return true
              }) else {
            isLiveDragPreview = false
            return
        }

        var baseComposition = comp
        baseComposition.elements.removeAll { selectedIDs.contains($0.id) }

        var selectionComposition = comp
        selectionComposition.elements = selectedElements
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
        GeometryReader { _ in
            ZStack {
                ForEach(selectedElements.filter { element in
                    if case .canvasEdge = element.kind { return false }
                    return true
                }) { element in
                    let frame = elementFrame(element, in: appState.composition, geometry: viewportGeometry(for: appState.composition))
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    // 画布 rotation 正值=逆时针；SwiftUI rotationEffect 屏幕坐标系正值=顺时针，需取反
                    let rotation = -element.transform.rotation
                    let isBackground = isBackgroundElement(element)
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(LF.header, lineWidth: 2)
                            .shadow(color: LF.header.opacity(0.28), radius: 3)

                        // 前景素材使用四个小控制点，背景素材继续使用下方的
                        // “背景取景”虚线框，避免在整张画布四角显示无意义的缩放点。
                        if !isBackground {
                            selectionHandles
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .rotationEffect(.radians(rotation))
                    .position(center)
                }
            }
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    private var selectionHandles: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
            selectionHandle.offset(x: -5, y: -5)
            }
            .overlay(alignment: .topTrailing) {
            selectionHandle.offset(x: 5, y: -5)
            }
            .overlay(alignment: .bottomLeading) {
            selectionHandle.offset(x: -5, y: 5)
            }
            .overlay(alignment: .bottomTrailing) {
            selectionHandle.offset(x: 5, y: 5)
            }
    }

    private var selectionHandle: some View {
        Circle()
            .fill(Color.white)
            .overlay {
                Circle().stroke(LF.header, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.18), radius: 2)
            .frame(width: 10, height: 10)
    }

    private func isBackgroundElement(_ element: CompositionElement) -> Bool {
        if case .background = element.kind { return true }
        return false
    }

    private var selectedElements: [CompositionElement] {
        guard let comp = appState.composition else { return [] }
        return comp.elements.filter { element in
            guard appState.selectedElementIDs.contains(element.id) else { return false }
            if case .canvasEdge = element.kind { return false }
            return true
        }
    }

    private var selectedBackgroundElement: CompositionElement? {
        guard appState.selectedElementIDs.count == 1,
              let id = appState.selectedElementIDs.first,
              let element = appState.composition?.elements.first(where: { $0.id == id }),
              case .background = element.kind else { return nil }
        return element
    }

    private var backgroundInteractionOverlay: some View {
        GeometryReader { _ in
            if let element = selectedBackgroundElement,
               let comp = appState.composition {
                let geometry = viewportGeometry(for: comp)
                let frame = elementFrame(element, in: comp, geometry: geometry)
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
                            Text(backgroundGestureKind?.title ?? "背景取景")
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
                beginCanvasManipulation()
            }
        }
    }

    private func beginCanvasManipulation() {
        guard !isCanvasManipulating else { return }
        isCanvasManipulating = true
        appState.beginCanvasEdit()
        refreshRendererScale()
    }

    private func endCanvasManipulation() {
        guard isCanvasManipulating || isBackgroundInteracting || backgroundGestureKind != nil else { return }
        backgroundGestureKind = nil
        isBackgroundInteracting = false
        isCanvasManipulating = false
        appState.finishCanvasEdit()
        refreshRendererScale()
        render()
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
            .buttonStyle(MagicButtonStyle(prominent: false))
            Button("重置") {
                cropRect = appState.composition?.canvasRect
                cropGestureStartRect = nil
            }
            .buttonStyle(MagicButtonStyle(prominent: false))
            Button("完成") {
                if let cropRect {
                    appState.setCropRect(cropRect)
                }
                appState.isCropping = false
            }
            .buttonStyle(MagicButtonStyle())
        }
    }

    /// 裁剪框叠加层：外部压暗 + 九宫格 + 可移动/缩放的矩形裁剪框。
    private var cropOverlay: some View {
        GeometryReader { geo in
            let viewport = geo.size
            if let cropRect, let comp = appState.composition {
                // 裁剪框在视口中的位置
                // 裁剪编辑时始终以完整画布为坐标系，允许把已裁剪区域重新扩大。
                let g = viewportGeometry(for: comp, contentRect: comp.canvasRect)
                let frame = CGRect(
                    x: g.offsetX + (cropRect.minX - g.rect.minX) * g.scale,
                    y: g.offsetY + (g.rect.maxY - cropRect.maxY) * g.scale,
                    width: cropRect.width * g.scale,
                    height: cropRect.height * g.scale
                )
                ZStack {
                    // 外部压暗（不拦截手势）
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: viewport))
                        path.addRect(frame)
                    }
                    .fill(LF.background.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    // 裁剪框内部可直接拖动，移动范围被限制在完整画布内。
                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .position(x: frame.midX, y: frame.midY)
                        .gesture(cropMoveGesture(geometry: g))

                    // 边框
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(LF.gold, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                    cropGrid(in: frame)

                    // 四角 + 四边手柄（可拖拽）
                    ForEach(CropHandle.allCases, id: \.self) { handle in
                        cropHandleView(handle)
                            .position(cropHandlePoint(handle, in: frame))
                            .gesture(cropHandleGesture(handle: handle, geometry: g))
                    }
                }
            }
        }
    }

    private func cropGrid(in frame: CGRect) -> some View {
        Path { path in
            let column = frame.width / 3
            let row = frame.height / 3
            for index in 1...2 {
                let x = frame.minX + column * CGFloat(index)
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))
                let y = frame.minY + row * CGFloat(index)
                path.move(to: CGPoint(x: frame.minX, y: y))
                path.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
        .stroke(LF.gold.opacity(0.34), lineWidth: 0.8)
        .allowsHitTesting(false)
    }

    private func cropHandleView(_ handle: CropHandle) -> some View {
        Group {
            if handle.isCorner {
                Circle()
                    .fill(LF.gold)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle().stroke(.black.opacity(0.4), lineWidth: 1)
                    }
            } else {
                Capsule()
                    .fill(LF.gold)
                    .frame(
                        width: handle.isHorizontal ? 34 : 4,
                        height: handle.isVertical ? 34 : 4
                    )
                    .overlay {
                        Capsule().stroke(.black.opacity(0.28), lineWidth: 0.8)
                    }
            }
        }
        .frame(width: handle.touchWidth, height: handle.touchHeight)
        .contentShape(Rectangle())
    }

    private func cropHandlePoint(_ handle: CropHandle, in frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeading: CGPoint(x: frame.minX, y: frame.minY)
        case .top: CGPoint(x: frame.midX, y: frame.minY)
        case .topTrailing: CGPoint(x: frame.maxX, y: frame.minY)
        case .leading: CGPoint(x: frame.minX, y: frame.midY)
        case .trailing: CGPoint(x: frame.maxX, y: frame.midY)
        case .bottomLeading: CGPoint(x: frame.minX, y: frame.maxY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY)
        case .bottomTrailing: CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }

    /// 拖动裁剪框主体，保持裁剪框大小不变并限制在完整画布内。
    private func cropMoveGesture(geometry: ViewportGeometry) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition,
                      let rect = cropRect else { return }
                if cropGestureStartRect == nil {
                    cropGestureStartRect = rect
                }
                guard let start = cropGestureStartRect else { return }
                let dx = value.translation.width / geometry.scale
                let dy = -value.translation.height / geometry.scale
                let canvas = comp.canvasRect
                let x = min(max(start.minX + dx, canvas.minX), canvas.maxX - start.width)
                let y = min(max(start.minY + dy, canvas.minY), canvas.maxY - start.height)
                cropRect = CGRect(x: x, y: y, width: start.width, height: start.height)
            }
            .onEnded { _ in
                cropGestureStartRect = nil
            }
    }

    /// 拖动裁剪框手柄（视口坐标 → 画布坐标，夹取到画布范围内，最小 50×50）。
    private func cropHandleGesture(
        handle: CropHandle, geometry: ViewportGeometry
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition, let rect = cropRect else { return }
                if cropGestureStartRect == nil {
                    cropGestureStartRect = rect
                }
                guard let start = cropGestureStartRect else { return }
                // 屏幕位移 → 画布位移（画布 y 向上，屏幕 y 向下：dy 取反）
                let dx = value.translation.width / geometry.scale
                let dy = -value.translation.height / geometry.scale
                let canvas = comp.canvasRect
                let minSize: CGFloat = 50
                var minX = start.minX
                var minY = start.minY
                var maxX = start.maxX
                var maxY = start.maxY
                switch handle {
                case .topLeading:
                    minX = min(max(start.minX + dx, canvas.minX), start.maxX - minSize)
                    maxY = max(min(start.maxY + dy, canvas.maxY), start.minY + minSize)
                case .top:
                    maxY = max(min(start.maxY + dy, canvas.maxY), start.minY + minSize)
                case .topTrailing:
                    maxX = max(min(start.maxX + dx, canvas.maxX), start.minX + minSize)
                    maxY = max(min(start.maxY + dy, canvas.maxY), start.minY + minSize)
                case .leading:
                    minX = min(max(start.minX + dx, canvas.minX), start.maxX - minSize)
                case .trailing:
                    maxX = max(min(start.maxX + dx, canvas.maxX), start.minX + minSize)
                case .bottomLeading:
                    minX = min(max(start.minX + dx, canvas.minX), start.maxX - minSize)
                    minY = min(max(start.minY + dy, canvas.minY), start.maxY - minSize)
                case .bottom:
                    minY = min(max(start.minY + dy, canvas.minY), start.maxY - minSize)
                case .bottomTrailing:
                    maxX = max(min(start.maxX + dx, canvas.maxX), start.minX + minSize)
                    minY = min(max(start.minY + dy, canvas.minY), start.maxY - minSize)
                }
                cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in
                cropGestureStartRect = nil
            }
    }

    // MARK: - 坐标换算

    /// 视口显示的区域（裁剪后），元素坐标按该区域映射到屏幕
    private func viewportGeometry(for comp: Composition?, contentRect: CGRect? = nil) -> ViewportGeometry {
        guard let comp, viewportSize.width > 0, viewportSize.height > 0 else {
            return ViewportGeometry(scale: 1, offsetX: 0, offsetY: 0, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let rect = contentRect ?? comp.renderRect
        let aspect = rect.width / rect.height
        let displayWidth = min(viewportSize.width, viewportSize.height * aspect)
        let displayHeight = displayWidth / aspect
        return ViewportGeometry(
            scale: displayWidth / rect.width,
            offsetX: (viewportSize.width - displayWidth) / 2,
            offsetY: (viewportSize.height - displayHeight) / 2,
            rect: rect
        )
    }

    private func canvasToViewportScale(_ comp: Composition) -> CGFloat {
        viewportGeometry(for: comp).scale
    }

    /// 元素在视口中的框（画布坐标 → 视口，y 翻转；忽略旋转用于命中与框选）
    private func elementFrame(_ element: CompositionElement, in comp: Composition?, geometry: ViewportGeometry) -> CGRect {
        guard let comp else { return .zero }
        // 分区背景的遮罩永远覆盖完整画布，且背景元素自身的 transform 不参与渲染。
        // 因此交互框也必须忽略旧 region/position，和最终可见区域保持一致。
        if case .background = element.kind,
           (element.backgroundSettings ?? BackgroundElementSettings()).splitCount != .full {
            let rect = comp.canvasRect
            let width = rect.width * geometry.scale
            let height = rect.height * geometry.scale
            return CGRect(
                x: geometry.offsetX,
                y: geometry.offsetY,
                width: width,
                height: height
            )
        }
        let size = elementContentSize(element, in: comp)
        let w = size.width * element.transform.scale * geometry.scale
        let h = size.height * element.transform.scale * geometry.scale
        let cx = geometry.offsetX + (element.transform.position.x - geometry.rect.minX) * geometry.scale
        let cy = geometry.offsetY + (geometry.rect.maxY - element.transform.position.y) * geometry.scale
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// 元素内容尺寸（clip 用素材尺寸，文字用排版估算，装饰/特效用画布比例估算）
    private func elementContentSize(_ element: CompositionElement, in comp: Composition) -> CGSize {
        if case .clip(let clipID) = element.kind,
           let clip = appState.clips.first(where: { $0.id == clipID }) {
            return CGSize(width: CGFloat(clip.width), height: CGFloat(clip.height))
        }
        if case .background = element.kind {
            let region = element.backgroundSettings?.region ?? .full
            let rect = region.rect(in: comp.canvasRect)
            return rect.size
        }
        if case .text(let textID) = element.kind,
           let text = comp.texts.first(where: { $0.id.uuidString == textID }) {
            return TextLayout.measuredSize(for: text, maxWidth: comp.canvas.width)
        }
        return CGSize(width: comp.canvas.width * 0.3, height: comp.canvas.height * 0.3)
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
            guard case .background = element.kind else { return nil }
            return element.backgroundSettings ?? BackgroundElementSettings()
        }
        // 分区遮罩必须与最终输出使用同一像素尺寸。单张背景也不能走预览降采样，
        // 否则 CI 的透明遮罩在缩放后可能出现分区边界错位；普通整幅背景仍保留降采样。
        return backgrounds.contains { $0.splitCount != .full } || backgrounds.count > 1
    }

    private func render() {
        renderVersion &+= 1

        guard !isRenderInFlight else { return }
        isRenderInFlight = true

        let version = renderVersion
        let composition = appState.composition.map { composition in
            guard appState.isCropping else { return composition }
            var fullCanvasPreview = composition
            fullCanvasPreview.cropRect = nil
            return fullCanvasPreview
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
        case .moving: "正在移动背景"
        case .scaling: "正在缩放背景"
        }
    }
}

private enum CropHandle: CaseIterable, Hashable {
    case topLeading
    case top
    case topTrailing
    case leading
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var isCorner: Bool {
        switch self {
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing:
            return true
        case .top, .leading, .trailing, .bottom:
            return false
        }
    }

    var isHorizontal: Bool {
        switch self {
        case .top, .bottom:
            return true
        case .topLeading, .topTrailing, .leading, .trailing, .bottomLeading, .bottomTrailing:
            return false
        }
    }

    var isVertical: Bool {
        switch self {
        case .leading, .trailing:
            return true
        case .topLeading, .top, .topTrailing, .bottomLeading, .bottom, .bottomTrailing:
            return false
        }
    }

    var touchWidth: CGFloat {
        isVertical ? 24 : 44
    }

    var touchHeight: CGFloat {
        isHorizontal ? 24 : 44
    }
}

private extension Dictionary where Key == UUID, Value == ElementTransform {
    /// 起始快照副本（手势期间不被后续更新覆盖）
    var snapshot: [UUID: ElementTransform]? {
        isEmpty ? nil : self
    }
}
