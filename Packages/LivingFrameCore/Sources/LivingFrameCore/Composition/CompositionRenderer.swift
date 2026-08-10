import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 统一渲染管线：预览与导出共用，保证所见即所得
/// 创作空间 = CI 左下原点坐标（y 向上），UI 层做坐标换算
public struct CompositionRenderer {
    private let context: CIContext
    private let decorationRenderer = DecorationRenderer()

    public init(context: CIContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])) {
        self.context = context
    }

    // MARK: - 输出

    public func render(_ composition: Composition, at time: TimeInterval) -> CGImage? {
        guard let ci = renderCIImage(composition, at: time) else { return nil }
        return context.createCGImage(ci, from: composition.canvasRect)
    }

    public func render(_ composition: Composition, at time: TimeInterval, into pixelBuffer: CVPixelBuffer) {
        guard let ci = renderCIImage(composition, at: time) else { return }
        context.render(ci, to: pixelBuffer, bounds: composition.canvasRect, colorSpace: nil)
    }

    // MARK: - 合成

    func renderCIImage(_ composition: Composition, at time: TimeInterval) -> CIImage? {
        let canvas = composition.canvasRect
        var image = backgroundCIImage(composition.background, in: canvas)
        for element in composition.elements.sorted(by: { $0.zIndex < $1.zIndex }) {
            guard element.isVisible(at: time) else { continue }
            if let placed = placedImage(for: element, at: time, canvas: canvas) {
                image = placed.composited(over: image)
            }
        }
        return image
    }

    private func backgroundCIImage(_ preset: BackgroundPreset, in rect: CGRect) -> CIImage {
        switch preset.kind {
        case .clear:
            return CIImage.clear.cropped(to: rect)
        case .solid:
            return CIImage(color: CIColor(hex: preset.topColor)).cropped(to: rect)
        case .gradient:
            let gradient = CIFilter.linearGradient()
            gradient.color0 = CIColor(hex: preset.topColor)
            gradient.color1 = CIColor(hex: preset.bottomColor)
            gradient.point0 = CGPoint(x: rect.midX, y: rect.maxY)
            gradient.point1 = CGPoint(x: rect.midX, y: rect.minY)
            return gradient.outputImage?.cropped(to: rect) ?? CIImage.clear.cropped(to: rect)
        }
    }

    private func placedImage(for element: CompositionElement, at time: TimeInterval, canvas: CGRect) -> CIImage? {
        let source: CIImage?
        switch element.kind {
        case .clip(let clipID):
            source = clipFrameImage(clipID: clipID, at: time)
        case .decoration(let decorationID):
            source = decorationRenderer.image(for: decorationID, canvas: canvas)
        case .effect(let effectID):
            source = decorationRenderer.image(for: effectID, canvas: canvas)
        }

        guard let ci = source else { return nil }
        var transform = CGAffineTransform(translationX: -ci.extent.midX, y: -ci.extent.midY)
        transform = transform.scaledBy(x: element.transform.scale, y: element.transform.scale)
        transform = transform.rotated(by: element.transform.rotation)
        transform = transform.translatedBy(x: element.transform.position.x, y: element.transform.position.y)
        return ci.transformed(by: transform)
    }

    private func clipFrameImage(clipID: String, at time: TimeInterval) -> CIImage? {
        guard let clip = FrameCache.shared.clip(id: clipID) else { return nil }
        let index = Int(time * clip.fps)
        guard let frame = clip.loadFrame(index: index) else { return nil }
        return CIImage(cgImage: frame)
    }
}

// MARK: - Color

extension CIColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")
        Scanner(string: hexString).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
