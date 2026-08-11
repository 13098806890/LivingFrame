import LivingFrameCore
import SwiftUI

/// 画布预览：CI 逐帧渲染 + 直接操作（点选 / 拖动 / 双指缩放 / 旋转 / 选中框）
struct CanvasView: View {
    @EnvironmentObject private var appState: AppState
    @State private var previewImage: UIImage?
    @State private var viewportSize: CGSize = .zero
    /// 预览渲染器：按视口尺寸解码/渲染，不改变导出分辨率
    @State private var renderer = CompositionRenderer(frameMaxPixelSize: 900)
    /// 手势起始快照（拖动/缩放/旋转共用）
    @State private var gestureStartTransforms: [UUID: ElementTransform] = [:]

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
                selectionOverlay
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

            playbackBar
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
    }

    private var canvasAspect: CGFloat {
        guard let comp = appState.composition else { return 9 / 16 }
        return comp.canvas.width / comp.canvas.height
    }

    // MARK: - 点选

    private func handleTap(at location: CGPoint) {
        guard let comp = appState.composition else { return }
        let geometry = viewportGeometry(for: comp)
        // 从顶层往下命中
        let hit = comp.elements
            .sorted { $0.zIndex > $1.zIndex }
            .first { element in
                elementFrame(element, in: comp, geometry: geometry).contains(location)
            }
        if let hit {
            appState.selectElement(hit.id)
        } else {
            appState.clearElementSelection()
        }
    }

    // MARK: - 拖动（移动全部选中素材）

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !appState.selectedElementIDs.isEmpty,
                      let comp = appState.composition else { return }
                let scale = canvasToViewportScale(comp)
                if gestureStartTransforms.isEmpty {
                    snapshotTransforms(comp)
                }
                guard let snaps = gestureStartTransforms.snapshot else { return }
                let dx = value.translation.width * scale
                let dy = value.translation.height * scale
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
                guard !appState.selectedElementIDs.isEmpty else { return }
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
            }
    }

    // MARK: - 旋转（旋转全部选中素材）

    private var rotateGesture: some Gesture {
        RotationGesture()
            .onChanged { value in
                guard !appState.selectedElementIDs.isEmpty else { return }
                if gestureStartTransforms.isEmpty {
                    snapshotTransforms(appState.composition)
                }
                guard let snaps = gestureStartTransforms.snapshot else { return }
                for id in appState.selectedElementIDs {
                    guard let start = snaps[id] else { continue }
                    appState.updateElement(id) { element in
                        element.transform.rotation = start.rotation + Double(value.radians)
                    }
                }
            }
            .onEnded { _ in
                gestureStartTransforms = [:]
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
        GeometryReader { geo in
            let geometry = viewportGeometry(for: appState.composition)
            ZStack {
                ForEach(selectedElements) { element in
                    let frame = elementFrame(element, in: appState.composition, geometry: geometry)
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(LF.gold, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .rotationEffect(.radians(element.transform.rotation))
                    ForEach(cornerPoints(of: frame), id: \.self) { point in
                        Circle()
                            .fill(LF.gold)
                            .frame(width: 8, height: 8)
                            .position(point)
                    }
                }
            }
            .allowsHitTesting(false)
            .frame(width: geo.size.width, height: geo.size.height)
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

    // MARK: - 坐标换算

    private func viewportGeometry(for comp: Composition?) -> ViewportGeometry {
        guard let comp, viewportSize.width > 0, viewportSize.height > 0 else {
            return ViewportGeometry(scale: 1, offsetX: 0, offsetY: 0, canvasHeight: 1)
        }
        let aspect = comp.canvas.width / comp.canvas.height
        let displayWidth = min(viewportSize.width, viewportSize.height * aspect)
        let displayHeight = displayWidth / aspect
        return ViewportGeometry(
            scale: displayWidth / comp.canvas.width,
            offsetX: (viewportSize.width - displayWidth) / 2,
            offsetY: (viewportSize.height - displayHeight) / 2,
            canvasHeight: comp.canvas.height
        )
    }

    private func canvasToViewportScale(_ comp: Composition) -> CGFloat {
        viewportGeometry(for: comp).scale
    }

    /// 元素在视口中的框（canvas 坐标 → 视口，y 翻转；忽略旋转用于命中与框选）
    private func elementFrame(_ element: CompositionElement, in comp: Composition?, geometry: ViewportGeometry) -> CGRect {
        guard let comp else { return .zero }
        let size = elementContentSize(element, in: comp)
        let w = size.width * element.transform.scale * geometry.scale
        let h = size.height * element.transform.scale * geometry.scale
        let cx = geometry.offsetX + element.transform.position.x * geometry.scale
        let cy = geometry.offsetY + (geometry.canvasHeight - element.transform.position.y) * geometry.scale
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// 元素内容尺寸（clip 用素材尺寸，装饰/特效用画布比例估算）
    private func elementContentSize(_ element: CompositionElement, in comp: Composition) -> CGSize {
        if case .clip(let clipID) = element.kind,
           let clip = appState.clips.first(where: { $0.id == clipID }) {
            return CGSize(width: CGFloat(clip.width), height: CGFloat(clip.height))
        }
        return CGSize(width: comp.canvas.width * 0.3, height: comp.canvas.height * 0.3)
    }

    // MARK: - 渲染

    /// 视口尺寸变化时重建预览渲染器（按屏幕像素渲染，预览清晰度足够且不浪费）
    private func refreshRendererScale() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let pixelScale = UIScreen.main.scale
        let maxPixel = max(viewportSize.width, viewportSize.height) * pixelScale * 1.1
        renderer = CompositionRenderer(frameMaxPixelSize: maxPixel)
    }

    private func render() {
        guard let comp = appState.composition else {
            previewImage = nil
            return
        }
        let time = min(appState.currentTime, comp.duration)
        if let cg = renderer.render(comp, at: time) {
            previewImage = UIImage(cgImage: cg)
        }
    }

    private var playbackBar: some View {
        HStack(spacing: 12) {
            Button {
                appState.isPlaying ? appState.pause() : appState.play()
            } label: {
                Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(LF.gold)
            }

            Slider(
                value: Binding(
                    get: { appState.currentTime },
                    set: { appState.seek(to: $0) }
                ),
                in: 0...max(appState.composition?.duration ?? 1, 0.1)
            )
            .tint(LF.gold)

            Text(timeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(LF.textSecondary)
        }
    }

    private var timeText: String {
        let total = appState.composition?.duration ?? 0
        return String(format: NSLocalizedString("time.progress", comment: "Playback time"), appState.currentTime, total)
    }
}

private struct ViewportGeometry {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let canvasHeight: CGFloat
}

private extension Dictionary where Key == UUID, Value == ElementTransform {
    /// 起始快照副本（手势期间不被后续更新覆盖）
    var snapshot: [UUID: ElementTransform]? {
        isEmpty ? nil : self
    }
}
