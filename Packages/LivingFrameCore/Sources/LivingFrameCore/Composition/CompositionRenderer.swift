import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 统一渲染管线：预览与导出共用，保证所见即所得
/// 创作空间 = CI 左下原点坐标（y 向上），UI 层做坐标换算
public struct CompositionRenderer {
    private let context: CIContext
    private let decorationRenderer = DecorationRenderer()
    /// 预览模式：素材帧与输出按此最大边解码/渲染（nil = 全分辨率，仅影响预览，不改变导出）
    private let frameMaxPixelSize: CGFloat?

    public init(
        context: CIContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]),
        frameMaxPixelSize: CGFloat? = nil
    ) {
        self.context = context
        self.frameMaxPixelSize = frameMaxPixelSize
    }

    // MARK: - 输出

    public func render(_ composition: Composition, at time: TimeInterval) -> CGImage? {
        guard let ci = renderCIImage(composition, at: time) else { return nil }
        if let frameMaxPixelSize {
            let size = composition.canvasRect.size
            let scale = min(1, frameMaxPixelSize / max(size.width, size.height))
            if scale < 1 {
                let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
                return context.createCGImage(scaled, from: CGRect(origin: .zero, size: scaledSize))
            }
        }
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
        case .image:
            guard let fileName = preset.imageFileName,
                  let cgImage = BackgroundStore.shared.loadImage(named: fileName) else {
                return CIImage(color: CIColor(hex: preset.topColor)).cropped(to: rect)
            }
            return CIImage(cgImage: cgImage)
                .transformed(by: aspectFillTransform(cgImageSize: CGSize(
                    width: cgImage.width, height: cgImage.height
                ), target: rect))
        }
    }

    /// 图片背景铺满画布（等比缩放裁切，不拉伸变形）
    private func aspectFillTransform(cgImageSize: CGSize, target: CGRect) -> CGAffineTransform {
        let imageSize = cgImageSize
        let scale = max(
            target.width / imageSize.width,
            target.height / imageSize.height
        )
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        return CGAffineTransform(translationX: -imageSize.width / 2, y: -imageSize.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: target.midX, y: target.midY)
    }

    private func placedImage(for element: CompositionElement, at time: TimeInterval, canvas: CGRect) -> CIImage? {
        let source: CIImage?
        switch element.kind {
        case .clip(let clipID):
            if let frame = clipFrameImage(clipID: clipID, at: time),
               let clip = FrameCache.shared.clip(id: clipID) {
                source = applyStickerStyle(clip.stickerStyle, to: applyEdgeStyle(clip.edgeStyle, to: frame))
            } else {
                source = nil
            }
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
        guard time.isFinite, clip.fps.isFinite, clip.fps > 0 else { return nil }
        let index = Int((time * clip.fps).rounded())
        let frame: CGImage?
        if let frameMaxPixelSize {
            frame = FrameCache.shared.cachedThumbnail(for: clip, index: index, maxPixelSize: frameMaxPixelSize)
        } else {
            frame = FrameCache.shared.cachedFrame(for: clip, index: index)
        }
        guard let frame else { return nil }
        return CIImage(cgImage: frame)
    }

    // MARK: - 边缘效果

    private func applyEdgeStyle(_ style: ClipEdgeStyle, to image: CIImage) -> CIImage {
        switch style {
        case .none:
            return image
        case .whiteOutline:
            return outlined(image, radius: 6, color: CIColor(hex: "FFFFFF"))
        case .blackOutline:
            return outlined(image, radius: 6, color: CIColor(hex: "000000"))
        case .goldOutline:
            return outlined(image, radius: 6, color: CIColor(hex: "E8C05C"))
        case .glow:
            return glow(image, color: CIColor(hex: "E8C05C"))
        case .shadow:
            return shadow(image)
        case .comic:
            let white = outlined(image, radius: 9, color: CIColor(hex: "FFFFFF"))
            let black = outlined(image, radius: 3, color: CIColor(hex: "000000"))
            return image.composited(over: black.composited(over: white))
        }
    }

    // MARK: - 贴纸风格（参照 iOS 贴纸效果）

    private func applyStickerStyle(_ style: StickerStyle, to image: CIImage) -> CIImage {
        switch style {
        case .none:
            return image
        case .outline:
            // 白色描边贴纸
            return outlined(image, radius: 5, color: CIColor(hex: "FFFFFF"))
        case .comic:
            // 漫画：粗黑描边
            return outlined(image, radius: 6, color: CIColor(hex: "000000"))
        case .puff:
            // 膨胀：轻微放大 + 边缘柔化
            let scaled = scaled(image, by: 1.1)
            return blurred(scaled, radius: 1.5)
        case .shrink:
            // 缩小
            return scaled(image, by: 0.9)
        case .smooth:
            // 平滑：羽化边缘
            return blurred(image, radius: 1.5)
        }
    }

    private func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: image.extent.midX, y: image.extent.midY))
    }

    private func blurred(_ image: CIImage, radius: CGFloat) -> CIImage {
        image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
    }

    /// 实心描边：alpha 遮罩膨胀后染色，垫在人物下层
    private func outlined(_ image: CIImage, radius: CGFloat, color: CIColor) -> CIImage {
        let mask = image.applyingFilter("CIMaskToAlpha")
        let expanded = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
        return tinted(expanded, color: color)
    }

    /// 柔光：alpha 遮罩膨胀 + 高斯模糊后染色
    private func glow(_ image: CIImage, color: CIColor) -> CIImage {
        let mask = image.applyingFilter("CIMaskToAlpha")
        let expanded = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 10])
        let blurred = expanded
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 16])
            .cropped(to: image.extent)
        return image.composited(over: tinted(blurred, color: color))
    }

    /// 投影：alpha 遮罩模糊后偏移染色（右下方向）
    private func shadow(_ image: CIImage) -> CIImage {
        let mask = image.applyingFilter("CIMaskToAlpha")
        let blurred = mask
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10])
            .cropped(to: image.extent)
        let shifted = blurred.transformed(by: CGAffineTransform(translationX: 14, y: -14))
        return image.composited(over: tinted(shifted, color: CIColor(hex: "000000")))
    }

    /// 用 CIColorMatrix 把遮罩染成纯色（RGB 置为颜色，alpha 保留遮罩值）
    private func tinted(_ mask: CIImage, color: CIColor) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = mask
        filter.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: color.red, y: color.green, z: color.blue, w: 0)
        return filter.outputImage ?? mask
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
