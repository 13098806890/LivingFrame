import LivingFrameCore
import SwiftUI

/// 画布预览：CI 逐帧渲染 + 拖拽移动选中元素
struct CanvasView: View {
    @EnvironmentObject private var appState: AppState
    @State private var previewImage: UIImage?
    @State private var viewportSize: CGSize = .zero

    private let renderer = CompositionRenderer()

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
                        }
                        .onChange(of: geo.size) { _, newValue in
                            viewportSize = newValue
                        }
                }
            )
            .gesture(dragGesture)

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
        guard let comp = appState.composition else { return 3 / 4 }
        return comp.canvas.width / comp.canvas.height
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

    // MARK: - 拖拽

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let id = appState.selectedElementID,
                      let comp = appState.composition,
                      comp.elements.contains(where: { $0.id == id }) else { return }
                let scale = canvasToViewportScale(comp)
                if appState.dragAnchor == nil {
                    appState.dragAnchor = comp.elements.first(where: { $0.id == id })?.transform.position
                }
                guard let anchor = appState.dragAnchor else { return }
                appState.updateElement(id) { element in
                    element.transform.position = CGPoint(
                        x: anchor.x + value.translation.width * scale,
                        y: anchor.y - value.translation.height * scale
                    )
                }
            }
            .onEnded { _ in
                appState.dragAnchor = nil
            }
    }

    private func canvasToViewportScale(_ comp: Composition) -> CGFloat {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        let displayWidth = min(viewportSize.width, viewportSize.height * comp.canvas.width / comp.canvas.height)
        guard displayWidth > 0 else { return 1 }
        return comp.canvas.width / displayWidth
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
}
