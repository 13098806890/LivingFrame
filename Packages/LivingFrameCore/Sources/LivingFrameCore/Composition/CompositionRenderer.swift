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
        let rect = composition.renderRect
        // 预览输出降采样到视口分辨率：先裁到画布区域再缩放，
        // 避免对整图（含画布外元素）缩放时超出区域被填黑
        if let frameMaxPixelSize {
            let size = rect.size
            let scale = min(1, frameMaxPixelSize / max(size.width, size.height))
            if scale < 1 {
                let cropped = ci.cropped(to: rect)
                let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
                return context.createCGImage(scaled, from: CGRect(origin: .zero, size: scaledSize))
            }
        }
        return context.createCGImage(ci, from: rect)
    }

    public func render(_ composition: Composition, at time: TimeInterval, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard let ci = renderCIImage(composition, at: time) else { return false }
        context.render(ci, to: pixelBuffer, bounds: composition.renderRect, colorSpace: nil)
        return true
    }

    // MARK: - 合成

    func renderCIImage(_ composition: Composition, at time: TimeInterval) -> CIImage? {
        let canvas = composition.canvasRect
        var image = backgroundCIImage(composition.background, in: canvas)
        for element in composition.elements.sorted(by: { $0.zIndex < $1.zIndex }) {
            guard element.isVisible(at: time) else { continue }
            // 跳过非法变换的元素（NaN/Inf 会导致整个画布渲染失败）
            let t = element.transform
            guard t.position.x.isFinite, t.position.y.isFinite,
                  t.scale.isFinite, t.scale > 0,
                  t.rotation.isFinite else {
                LogStore.log("renderCIImage: 跳过非法变换元素 id=\(element.id) transform=\(t)")
                continue
            }
            if let placed = placedImage(for: element, at: time, canvas: canvas) {
                image = placed.composited(over: image)
            } else {
                LogStore.log("renderCIImage: 元素渲染失败 kind=\(element.kind) time=\(time)")
            }
        }
        // 统一裁剪到画布：任何背景/元素 extent 异常都不会产生未覆盖黑块
        return image.cropped(to: canvas)
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
            // 必须裁剪到画布：背景 extent 与画布一致，避免合成/渲染未覆盖区域被填黑
            return CIImage(cgImage: cgImage)
                .transformed(by: aspectFillTransform(cgImageSize: CGSize(
                    width: cgImage.width, height: cgImage.height
                ), target: rect))
                .cropped(to: rect)
        case .pattern:
            guard let style = preset.patternStyle,
                  let cgImage = LinePattern.image(
                      width: Int(rect.width),
                      height: Int(rect.height),
                      style: style
                  ) else {
                return CIImage(color: CIColor(hex: "FFFFFF")).cropped(to: rect)
            }
            return CIImage(cgImage: cgImage).cropped(to: rect)
        }
    }

    /// 图片背景铺满画布（等比缩放裁切，不拉伸变形）
    /// 应用顺序：图片中心移到原点 → 等比缩放 → 平移到画布中心
    private func aspectFillTransform(cgImageSize: CGSize, target: CGRect) -> CGAffineTransform {
        let imageSize = cgImageSize
        let scale = max(
            target.width / imageSize.width,
            target.height / imageSize.height
        )
        var transform = CGAffineTransform(translationX: target.midX, y: target.midY)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: -imageSize.width / 2, y: -imageSize.height / 2)
        return transform
    }

    private func placedImage(for element: CompositionElement, at time: TimeInterval, canvas: CGRect) -> CIImage? {
        let source: CIImage?
        var fixScale: CGFloat = 1
        switch element.kind {
        case .clip(let clipID):
            if let frame = clipFrameImage(clipID: clipID, at: time),
               let clip = FrameCache.shared.clip(id: clipID) {
                // 预览用缩略图（尺寸 < 素材实际像素）。不把源图放大回全尺寸——
                // 放大插值会在人物边缘产生半透明残留像素（贴边时形成"阴影线"）。
                // 改为把归一化因子并入元素缩放，源图始终一次缩放到位。
                fixScale = clip.width > 0 && Int(frame.extent.width) > 0
                    ? CGFloat(clip.width) / frame.extent.width
                    : 1
                source = applyStickerStyle(
                    clip.stickerStyle,
                    to: applyEdgeStyle(
                        clip.edgeStyle,
                        lineStyle: clip.edgeLineStyle,
                        thickness: clip.edgeThickness,
                        colorHex: clip.edgeColorHex,
                        to: frame
                    )
                )
            } else {
                LogStore.log("placedImage: clip 帧获取失败 clipID=\(clipID) time=\(time) registered=\(FrameCache.shared.clip(id: clipID) != nil)")
                source = nil
            }
        case .decoration(let decorationID):
            source = decorationRenderer.image(for: decorationID, canvas: canvas)
        case .effect(let effectID):
            source = decorationRenderer.image(for: effectID, canvas: canvas)
        }

        guard let ci = source else { return nil }
        // CGAffineTransform 链为右乘：新变换先应用。
        // 目标应用顺序：平移到元素中心(-mid) → 缩放 → 旋转 → 平移到目标位置(position)。
        // 因此矩阵必须从"最后应用"的变换开始构造。
        // fixScale 把缩略图尺寸换算到素材实际像素尺寸，保证元素渲染尺寸与全尺寸一致。
        let effectiveScale = element.transform.scale * fixScale
        var transform = CGAffineTransform(
            translationX: element.transform.position.x,
            y: element.transform.position.y
        )
        transform = transform.rotated(by: element.transform.rotation)
        transform = transform.scaledBy(x: effectiveScale, y: effectiveScale)
        transform = transform.translatedBy(x: -ci.extent.midX, y: -ci.extent.midY)
        return ci.transformed(by: transform)
    }

    private func clipFrameImage(clipID: String, at time: TimeInterval) -> CIImage? {
        guard let clip = FrameCache.shared.clip(id: clipID) else { return nil }
        guard time.isFinite, clip.fps.isFinite, clip.fps > 0, clip.frameCount > 0 else {
            // fps 异常时尝试第 0 帧（静态图）
            if let frame = FrameCache.shared.cachedFrame(for: clip, index: 0) {
                return CIImage(cgImage: frame)
            }
            return nil
        }
        let rawIndex = Int((time * clip.fps).rounded())
        let index = min(max(rawIndex, 0), clip.frameCount - 1)
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

    private func applyEdgeStyle(
        _ style: ClipEdgeStyle,
        lineStyle: EdgeLineStyle,
        thickness: EdgeThickness,
        colorHex: String,
        to image: CIImage
    ) -> CIImage {
        let color = CIColor(hex: colorHex)
        switch style {
        case .none:
            return image
        case .outline, .whiteOutline, .blackOutline, .goldOutline,
             .outlineSolid, .outlineDashed, .outlineDotted:
            // 组合描边：样式 × 粗细 × 颜色
            return outlined(image, radius: thickness.radius, color: color, lineStyle: lineStyle)
        case .glow:
            return glow(image, color: CIColor(hex: "E8C05C"))
        case .shadow:
            return shadow(image)
        case .comic:
            let white = outlineLayer(image, radius: 9, color: CIColor(hex: "FFFFFF"), lineStyle: .solid)
            let black = outlineLayer(image, radius: 3, color: CIColor(hex: "000000"), lineStyle: .solid)
            return image.composited(over: black.composited(over: white))
        }
    }

    // MARK: - 贴纸风格（参照 iOS 贴纸 STKStickerEffect）

    private func applyStickerStyle(_ style: StickerStyle, to image: CIImage) -> CIImage {
        // 苹果描边/漫画宽度与主体尺寸成比例（约短边 3%/7%），预览与导出表现一致
        let base = min(image.extent.width, image.extent.height)
        switch style {
        case .none:
            return image
        case .outline:
            // 描边贴纸：白色描边（宽度≈短边 3%），边缘柔和渐变
            let radius = max(6, min(base * 0.03, 24))
            let layer = outlineLayer(image, radius: radius, color: CIColor(hex: "FFFFFF"), lineStyle: .solid)
            let soft = layer
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, radius * 0.25)])
                .cropped(to: image.extent)
            return image.composited(over: soft)
        case .comic:
            // 漫画贴纸：黑粗外描边（≈短边 7%）+ 白色细边紧贴主体内侧。
            // 白层半径略小于黑层，盖住主体边缘 1-2px，形成主体边缘白边 + 外圈黑边的漫画线稿感
            let blackRadius = max(10, min(base * 0.07, 40))
            let whiteRadius = max(3, blackRadius - 4)
            let black = outlineLayer(image, radius: blackRadius, color: CIColor(hex: "000000"), lineStyle: .solid)
            let white = outlineLayer(image, radius: whiteRadius, color: CIColor(hex: "FFFFFF"), lineStyle: .solid)
            return image.composited(over: white.composited(over: black))
        case .smooth:
            // 平滑贴纸：轻微边缘羽化
            return blurred(image, radius: max(1, min(base * 0.012, 6)))
        }
    }

    private func blurred(_ image: CIImage, radius: CGFloat) -> CIImage {
        image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
    }

    /// 描边：人物在上，描边层垫在下层
    private func outlined(_ image: CIImage, radius: CGFloat, color: CIColor, lineStyle: EdgeLineStyle) -> CIImage {
        image.composited(over: outlineLayer(image, radius: radius, color: color, lineStyle: lineStyle))
    }

    /// 生成描边层：整图形态学膨胀（alpha 同步外扩）→ 按样式裁切（实线/线段）→ 染成纯色
    private func outlineLayer(_ image: CIImage, radius: CGFloat, color: CIColor, lineStyle: EdgeLineStyle) -> CIImage {
        let expanded = image.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
        let styled: CIImage
        switch lineStyle {
        case .solid:
            styled = expanded
        case .dashed:
            // 线段（虚线）：与实线完全相同的膨胀环，沿环方向开细缝切成段。
            // 缝沿径向（垂直轮廓）且很细（6°），段沿轮廓方向、端部垂直轮廓，
            // 间隔约 30%——这是"去掉实线中的一部分"的正确几何。
            let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            let sector = SectorPattern.image(
                width: Int(expanded.extent.width),
                height: Int(expanded.extent.height),
                center: center,
                segmentDegrees: 20,
                gapDegrees: 6
            )
            if let sector {
                let pattern = CIImage(cgImage: sector).cropped(to: expanded.extent)
                styled = expanded.applyingFilter("CIMultiplyBlendMode", parameters: [
                    kCIInputBackgroundImageKey: pattern
                ])
            } else {
                styled = expanded
            }
        }
        return tinted(styled, color: color)
    }

    /// 柔光：人物在上，光晕层（膨胀+模糊+染色）垫在下层
    private func glow(_ image: CIImage, color: CIColor) -> CIImage {
        let expanded = image.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 10])
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

    /// 用 alpha 掩码染色：纯色 × 掩码（RGB 置为颜色，alpha 完全来自掩码）。
    /// 不使用 CIColorMatrix（其在部分系统上 alpha 处理不可靠，会把透明区域染成不透明）
    private func tinted(_ mask: CIImage, color: CIColor) -> CIImage {
        let solid = CIImage(color: color).cropped(to: mask.extent)
        let clear = CIImage.clear.cropped(to: mask.extent)
        let alpha = mask.applyingFilter("CIMaskToAlpha")
        return solid.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: alpha,
            kCIInputBackgroundImageKey: clear
        ])
    }
}

// MARK: - 背景线条图案

/// 代码绘制背景线条图案（横线/斜线/网格/马赛克），按参数缓存
private enum LinePattern {
    static let lock = NSLock()
    static var cache: [String: CGImage] = [:]

    static func image(width: Int, height: Int, style: BackgroundPatternStyle) -> CGImage? {
        let key = "\(width)-\(height)-\(style.pattern.rawValue)-\(Int(style.lineWidth))-\(style.colorHex)-\(Int(style.spacing))"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let drawn = draw(width: width, height: height, style: style) else { return nil }
        lock.lock()
        cache[key] = drawn
        lock.unlock()
        return drawn
    }

    private static func draw(width: Int, height: Int, style: BackgroundPatternStyle) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // 浅色底
        ctx.setFillColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let lineColor = style.colorHex.hexComponents()
        ctx.setStrokeColor(red: lineColor.r, green: lineColor.g, blue: lineColor.b, alpha: 1)
        ctx.setLineWidth(style.lineWidth)

        switch style.pattern {
        case .horizontal:
            for y in stride(from: 0, through: height, by: Int(style.spacing)) {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: width, y: y))
            }
        case .diagonal:
            let diagonal = sqrt(CGFloat(width * width + height * height))
            for offset in stride(from: -diagonal, through: diagonal, by: style.spacing) {
                ctx.move(to: CGPoint(x: CGFloat(width) + offset, y: 0))
                ctx.addLine(to: CGPoint(x: offset, y: CGFloat(height)))
            }
        case .grid:
            for x in stride(from: 0, through: width, by: Int(style.spacing)) {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: height))
            }
            for y in stride(from: 0, through: height, by: Int(style.spacing)) {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: width, y: y))
            }
        case .mosaic:
            // 深浅交替方块（以线条色为深色）
            let cell = style.spacing
            var row = 0
            var y: CGFloat = 0
            while y < CGFloat(height) {
                var x: CGFloat = (row % 2 == 0) ? 0 : -cell / 2
                while x < CGFloat(width) {
                    if (Int(x / cell) + row) % 2 == 0 {
                        ctx.setFillColor(red: lineColor.r, green: lineColor.g, blue: lineColor.b, alpha: 1)
                    } else {
                        ctx.setFillColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1)
                    }
                    ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                    x += cell
                }
                row += 1
                y += cell
            }
        }
        ctx.strokePath()
        return ctx.makeImage()
    }
}

extension String {
    /// hex 颜色字符串拆分为 RGB 分量
    fileprivate func hexComponents() -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var value: UInt64 = 0
        var hex = trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        Scanner(string: hex).scanHexInt64(&value)
        return (
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
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

// MARK: - 虚线切缝图案

/// 沿描边环开细缝用的图案：白底 + 从中心辐射的黑色窄缝（垂直轮廓方向）。
/// 缝很细（如 6°）不会产生放射感，切出的段沿轮廓方向、端部垂直轮廓。
private enum SectorPattern {
    static let lock = NSLock()
    static var cache: [String: CGImage] = [:]

    static func image(
        width: Int, height: Int, center: CGPoint, segmentDegrees: CGFloat, gapDegrees: CGFloat
    ) -> CGImage? {
        let key = "\(width)-\(height)-\(Int(segmentDegrees))-\(Int(gapDegrees))"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let drawn = draw(
            width: width, height: height, center: center,
            segmentDegrees: segmentDegrees, gapDegrees: gapDegrees
        ) else { return nil }
        lock.lock()
        cache[key] = drawn
        lock.unlock()
        return drawn
    }

    /// 白底 + 黑色窄缝（从中心辐射，角度宽 = gapDegrees，周期 = segmentDegrees）
    private static func draw(
        width: Int, height: Int, center: CGPoint,
        segmentDegrees: CGFloat, gapDegrees: CGFloat
    ) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let maxR = hypot(CGFloat(width), CGFloat(height))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        var angle: CGFloat = 0
        while angle < 360 {
            let start = angle * .pi / 180
            let end = (angle + gapDegrees) * .pi / 180
            let path = CGMutablePath()
            path.move(to: center)
            path.addArc(center: center, radius: maxR, startAngle: start, endAngle: end, clockwise: false)
            path.closeSubpath()
            ctx.addPath(path)
            angle += segmentDegrees
        }
        ctx.fillPath()
        return ctx.makeImage()
    }
}
