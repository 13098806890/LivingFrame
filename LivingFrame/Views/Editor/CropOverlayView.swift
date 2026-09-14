import SwiftUI

/// Shared crop-box interaction for the editor canvas and material detail preview.
struct CropOverlayView: View {
    let contentRect: CGRect
    let minimumCropSize: CGFloat
    @Binding var cropRect: CGRect?
    @State private var gestureStartRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            if let cropRect {
                let geometry = CropOverlayGeometry(contentRect: contentRect, viewport: viewport)
                let frame = CGRect(
                    x: geometry.offsetX + (cropRect.minX - geometry.rect.minX) * geometry.scale,
                    y: geometry.offsetY + (geometry.rect.maxY - cropRect.maxY) * geometry.scale,
                    width: cropRect.width * geometry.scale,
                    height: cropRect.height * geometry.scale
                )

                ZStack {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: viewport))
                        path.addRect(frame)
                    }
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .position(x: frame.midX, y: frame.midY)
                        .gesture(moveGesture(geometry: geometry))

                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)

                    grid(in: frame)

                    ForEach(CropHandle.allCases, id: \.self) { handle in
                        handleView(handle)
                            .position(handlePoint(handle, in: frame))
                            .gesture(handleGesture(handle: handle, geometry: geometry))
                    }
                }
            }
        }
    }

    private func grid(in frame: CGRect) -> some View {
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
        .stroke(Color.white.opacity(0.34), lineWidth: 0.8)
        .allowsHitTesting(false)
    }

    private func handleView(_ handle: CropHandle) -> some View {
        Group {
            if handle.isCorner {
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .overlay { Circle().stroke(Color.black.opacity(0.4), lineWidth: 1) }
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(
                        width: handle.isHorizontal ? 34 : 4,
                        height: handle.isVertical ? 34 : 4
                    )
                    .overlay { Capsule().stroke(Color.black.opacity(0.28), lineWidth: 0.8) }
            }
        }
        .frame(width: handle.touchWidth, height: handle.touchHeight)
        .contentShape(Rectangle())
    }

    private func handlePoint(_ handle: CropHandle, in frame: CGRect) -> CGPoint {
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

    private func moveGesture(geometry: CropOverlayGeometry) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let rect = cropRect else { return }
                if gestureStartRect == nil { gestureStartRect = rect }
                guard let start = gestureStartRect else { return }
                let dx = value.translation.width / geometry.scale
                let dy = -value.translation.height / geometry.scale
                let x = min(max(start.minX + dx, contentRect.minX), contentRect.maxX - start.width)
                let y = min(max(start.minY + dy, contentRect.minY), contentRect.maxY - start.height)
                cropRect = CGRect(x: x, y: y, width: start.width, height: start.height)
            }
            .onEnded { _ in gestureStartRect = nil }
    }

    private func handleGesture(
        handle: CropHandle,
        geometry: CropOverlayGeometry
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let rect = cropRect else { return }
                if gestureStartRect == nil { gestureStartRect = rect }
                guard let start = gestureStartRect else { return }
                let dx = value.translation.width / geometry.scale
                let dy = -value.translation.height / geometry.scale
                var minX = start.minX
                var minY = start.minY
                var maxX = start.maxX
                var maxY = start.maxY
                switch handle {
                case .topLeading:
                    minX = min(max(start.minX + dx, contentRect.minX), start.maxX - minimumCropSize)
                    maxY = max(min(start.maxY + dy, contentRect.maxY), start.minY + minimumCropSize)
                case .top:
                    maxY = max(min(start.maxY + dy, contentRect.maxY), start.minY + minimumCropSize)
                case .topTrailing:
                    maxX = max(min(start.maxX + dx, contentRect.maxX), start.minX + minimumCropSize)
                    maxY = max(min(start.maxY + dy, contentRect.maxY), start.minY + minimumCropSize)
                case .leading:
                    minX = min(max(start.minX + dx, contentRect.minX), start.maxX - minimumCropSize)
                case .trailing:
                    maxX = max(min(start.maxX + dx, contentRect.maxX), start.minX + minimumCropSize)
                case .bottomLeading:
                    minX = min(max(start.minX + dx, contentRect.minX), start.maxX - minimumCropSize)
                    minY = min(max(start.minY + dy, contentRect.minY), start.maxY - minimumCropSize)
                case .bottom:
                    minY = min(max(start.minY + dy, contentRect.minY), start.maxY - minimumCropSize)
                case .bottomTrailing:
                    maxX = max(min(start.maxX + dx, contentRect.maxX), start.minX + minimumCropSize)
                    minY = min(max(start.minY + dy, contentRect.minY), start.maxY - minimumCropSize)
                }
                cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in gestureStartRect = nil }
    }
}

private struct CropOverlayGeometry {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let rect: CGRect

    init(contentRect: CGRect, viewport: CGSize) {
        let aspect = contentRect.width / max(contentRect.height, 0.01)
        let displayWidth = min(viewport.width, viewport.height * aspect)
        let displayHeight = displayWidth / max(aspect, 0.01)
        scale = displayWidth / max(contentRect.width, 0.01)
        offsetX = (viewport.width - displayWidth) / 2
        offsetY = (viewport.height - displayHeight) / 2
        rect = contentRect
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
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing: true
        case .top, .leading, .trailing, .bottom: false
        }
    }

    var isHorizontal: Bool {
        switch self {
        case .top, .bottom: true
        default: false
        }
    }

    var isVertical: Bool {
        switch self {
        case .leading, .trailing: true
        default: false
        }
    }

    var touchWidth: CGFloat { isVertical ? 24 : 44 }
    var touchHeight: CGFloat { isHorizontal ? 24 : 44 }
}
