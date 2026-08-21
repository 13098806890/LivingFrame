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
    /// 双指手势活跃中（防止同时触发拖动）
    @State private var isPinching = false
    /// 裁剪模式下的临时裁剪框（画布坐标系）
    @State private var cropRect: CGRect?
    /// 渲染版本号：异步渲染完成时只有最新版本才写入，避免旧帧覆盖新帧。
    @State private var renderVersion = 0
    /// 是否有一个预览渲染正在执行；执行期间只保留最新请求，避免任务堆积或全部被跳过。
    @State private var isRenderInFlight = false
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
                if let previewImage {
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
                }
            }
            .background {
                if appState.composition?.background.kind == .clear {
                    CheckerboardView()
                }
            }
            .aspectRatio(canvasAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LF.surface2, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 9)
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
            render()
        }
        .onChange(of: appState.composition) { _, _ in
            render()
        }
        .onChange(of: appState.currentTime) { _, _ in
            render()
        }
        .onChange(of: appState.isPlaying) { _, playing in
            if playing {
                render()
            }
        }
        .onChange(of: appState.clipStyleVersion) { _, _ in
            render()
        }
        .onChange(of: appState.isCropping) { _, cropping in
            if cropping {
                cropRect = appState.composition?.renderRect
            }
        }
    }

    private var canvasAspect: CGFloat {
        guard let comp = appState.composition else { return 9 / 16 }
        let rect = comp.renderRect
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
                }
                guard let snaps = gestureStartTransforms.snapshot else { return }
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                for id in appState.selectedElementIDs {
                    guard let start = snaps[id] else { continue }
                    appState.updateElement(id) { element in
                        element.transform.position = CGPoint(
                            x: start.position.x + dx,
                            y: start.position.y - dy
                        )
                    }
                }
            }
            .onEnded { _ in
                gestureStartTransforms = [:]
            }
    }

    // MARK: - 双指缩放（缩放全部选中素材）

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard !appState.isCropping, !appState.selectedElementIDs.isEmpty else { return }
                isPinching = true
                if gestureStartTransforms.isEmpty {
                    snapshotTransforms(appState.composition)
                }
                guard let snaps = gestureStartTransforms.snapshot else { return }
                for id in appState.selectedElementIDs {
                    guard let start = snaps[id] else { continue }
                    appState.updateElement(id) { element in
                        element.transform.scale = max(0.1, min(10, start.scale * value))
                    }
                }
            }
            .onEnded { _ in
                gestureStartTransforms = [:]
                isPinching = false
            }
    }

    // MARK: - 旋转（旋转全部选中素材）

    private var rotateGesture: some Gesture {
        RotationGesture()
            .onChanged { value in
                guard !appState.isCropping, !appState.selectedElementIDs.isEmpty else { return }
                isPinching = true
                if gestureStartTransforms.isEmpty {
                    snapshotTransforms(appState.composition)
                }
                guard let snaps = gestureStartTransforms.snapshot else { return }
                for id in appState.selectedElementIDs {
                    guard let start = snaps[id] else { continue }
                    appState.updateElement(id) { element in
                        // RotationGesture 正值=顺时针（屏幕 y 向下），画布 y 向上需取反
                        element.transform.rotation = start.rotation - Double(value.radians)
                    }
                }
            }
            .onEnded { _ in
                gestureStartTransforms = [:]
                isPinching = false
            }
    }

    private func snapshotTransforms(_ comp: Composition?) {
        guard let comp else { return }
        var snaps: [UUID: ElementTransform] = [:]
        for id in appState.selectedElementIDs {
            if let element = comp.elements.first(where: { $0.id == id }) {
                snaps[id] = element.transform
            }
        }
        gestureStartTransforms = snaps
    }

    // MARK: - 选中框

    private var selectionOverlay: some View {
        GeometryReader { _ in
            ZStack {
                ForEach(selectedElements) { element in
                    let frame = elementFrame(element, in: appState.composition, geometry: viewportGeometry(for: appState.composition))
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    // 画布 rotation 正值=逆时针；SwiftUI rotationEffect 屏幕坐标系正值=顺时针，需取反
                    let rotation = -element.transform.rotation
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.95), lineWidth: 1.5)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .frame(width: frame.width, height: frame.height)
                        .rotationEffect(.radians(rotation))
                        .position(center)
                }
            }
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    private var selectedElements: [CompositionElement] {
        guard let comp = appState.composition else { return [] }
        return comp.elements.filter { appState.selectedElementIDs.contains($0.id) }
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

    /// 裁剪框叠加层：外部压暗 + 金色边框 + 四角拖拽手柄
    private var cropOverlay: some View {
        GeometryReader { geo in
            let viewport = geo.size
            if let cropRect, let comp = appState.composition {
                // 裁剪框在视口中的位置
                let g = viewportGeometry(for: comp)
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
                    // 边框
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(LF.gold, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                    // 四角手柄（可拖拽）
                    ForEach(Array(cornerPoints(of: frame).enumerated()), id: \.offset) { _, point in
                        Circle()
                            .fill(LF.gold)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle().stroke(.black.opacity(0.4), lineWidth: 1)
                            }
                            .position(point)
                            .gesture(cropHandleGesture(corner: point, frame: frame, geometry: g, viewport: viewport))
                    }
                }
            }
        }
    }

    /// 拖动裁剪框角点（视口坐标 → 画布坐标，夹取到画布范围内，最小 50×50）
    private func cropHandleGesture(
        corner: CGPoint, frame: CGRect, geometry: ViewportGeometry, viewport: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition, let rect = cropRect else { return }
                // 屏幕位移 → 画布位移（画布 y 向上，屏幕 y 向下：dy 取反）
                let dx = value.translation.width / geometry.scale
                let dy = -value.translation.height / geometry.scale
                let canvas = comp.canvasRect
                let minSize: CGFloat = 50
                var minX = rect.minX
                var minY = rect.minY
                var maxX = rect.maxX
                var maxY = rect.maxY
                if corner.x == frame.minX {
                    minX = min(max(rect.minX + dx, canvas.minX), rect.maxX - minSize)
                }
                if corner.x == frame.maxX {
                    maxX = max(min(rect.maxX + dx, canvas.maxX), rect.minX + minSize)
                }
                if corner.y == frame.minY {
                    // 屏幕上边（画布 maxY）
                    maxY = max(min(rect.maxY + dy, canvas.maxY), rect.minY + minSize)
                }
                if corner.y == frame.maxY {
                    // 屏幕下边（画布 minY）
                    minY = min(max(rect.minY + dy, canvas.minY), rect.maxY - minSize)
                }
                cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
    }

    // MARK: - 坐标换算

    /// 视口显示的区域（裁剪后），元素坐标按该区域映射到屏幕
    private func viewportGeometry(for comp: Composition?) -> ViewportGeometry {
        guard let comp, viewportSize.width > 0, viewportSize.height > 0 else {
            return ViewportGeometry(scale: 1, offsetX: 0, offsetY: 0, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let rect = comp.renderRect
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
        if case .text(let textID) = element.kind,
           let text = comp.texts.first(where: { $0.id.uuidString == textID }) {
            // 单行估算：宽 ≈ 字符数 × 0.6 × 字号（上限画布宽），高 ≈ 1.2 × 字号
            let charWidth = CGFloat(text.text.count) * text.fontSize * 0.6
            return CGSize(
                width: min(charWidth, comp.canvas.width),
                height: text.fontSize * 1.2
            )
        }
        return CGSize(width: comp.canvas.width * 0.3, height: comp.canvas.height * 0.3)
    }

    // MARK: - 渲染

    /// 视口尺寸变化时重建预览渲染器（按屏幕像素渲染，预览清晰度足够且不浪费）
    private func refreshRendererScale() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let pixelScale = UIScreen.main.scale
        // 编辑预览不需要按 Retina 全分辨率渲染；多素材同时播放时，
        // 把中间合成限制在 900px 内，避免渲染队列长期追不上播放时钟。
        let maxPixel = min(
            max(viewportSize.width, viewportSize.height) * pixelScale * 1.1,
            900
        )
        renderer = CompositionRenderer(frameMaxPixelSize: maxPixel)
    }

    private func render() {
        renderVersion &+= 1

        guard !isRenderInFlight else { return }
        isRenderInFlight = true

        let version = renderVersion
        let composition = appState.composition
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

private extension Dictionary where Key == UUID, Value == ElementTransform {
    /// 起始快照副本（手势期间不被后续更新覆盖）
    var snapshot: [UUID: ElementTransform]? {
        isEmpty ? nil : self
    }
}
