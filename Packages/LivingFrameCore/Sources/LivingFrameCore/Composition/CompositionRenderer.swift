import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
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
            if let placed = placedImage(for: element, at: time, canvas: canvas, composition: composition) {
                image = placed.composited(over: image)
            } else {
                LogStore.log("renderCIImage: 元素渲染失败 kind=\(element.kind) time=\(time)")
            }
        }
        // 统一裁剪到画布：任何背景/元素 extent 异常都不会产生未覆盖黑块
        return image.cropped(to: canvas)
    }

    private func backgroundCIImage(_ preset: BackgroundPreset, in rect: CGRect) -> CIImage {
        let base: CIImage
        switch preset.kind {
        case .clear:
            base = CIImage.clear.cropped(to: rect)
        case .solid:
            base = CIImage(color: CIColor(hex: preset.topColor)).cropped(to: rect)
        case .gradient:
            let gradient = CIFilter.linearGradient()
            gradient.color0 = CIColor(hex: preset.topColor)
            gradient.color1 = CIColor(hex: preset.bottomColor)
            gradient.point0 = CGPoint(x: rect.midX, y: rect.maxY)
            gradient.point1 = CGPoint(x: rect.midX, y: rect.minY)
            base = gradient.outputImage?.cropped(to: rect) ?? CIImage.clear.cropped(to: rect)
        case .image:
            guard let fileName = preset.imageFileName,
                  let cgImage = BackgroundStore.shared.loadImage(named: fileName) else {
                base = CIImage(color: CIColor(hex: preset.topColor)).cropped(to: rect)
                break
            }
            // 必须裁剪到画布：背景 extent 与画布一致，避免合成/渲染未覆盖区域被填黑
            base = CIImage(cgImage: cgImage)
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
                base = CIImage(color: CIColor(hex: "FFFFFF")).cropped(to: rect)
                break
            }
            base = CIImage(cgImage: cgImage).cropped(to: rect)
        }
        // 叠加层：在底层背景上叠加透明底线条/网格图案图层
        if let overlay = preset.patternOverlay,
           let overlayCG = LinePattern.image(
               width: Int(rect.width),
               height: Int(rect.height),
               style: overlay,
               transparentBackground: true
           ) {
            return CIImage(cgImage: overlayCG).cropped(to: rect).composited(over: base)
        }
        return base
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

    private func placedImage(for element: CompositionElement, at time: TimeInterval, canvas: CGRect, composition: Composition) -> CIImage? {
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
                // 元素级背景图案垫在底层（先画背景，再叠加人物及其边缘/风格）
                var content: CIImage
                if clip.stickerStyle == .customOutline {
                    // 自定义描边：线型×粗细×颜色参数直接渲染，不叠加旧边缘层
                    content = outlined(
                        frame,
                        radius: clip.edgeThickness.radius / fixScale,
                        color: CIColor(hex: clip.edgeColorHex),
                        lineStyle: clip.edgeLineStyle,
                        fixScale: fixScale,
                        clipID: clip.id,
                        frameIndex: min(max(Int((time * clip.fps).rounded()), 0), max(clip.frameCount - 1, 0))
                    )
                } else {
                    content = applyStickerStyle(
                        clip.stickerStyle,
                        to: applyEdgeStyle(
                            clip.edgeStyle,
                            lineStyle: clip.edgeLineStyle,
                            thickness: clip.edgeThickness,
                            colorHex: clip.edgeColorHex,
                            fixScale: fixScale,
                            clipID: clip.id,
                            frameIndex: min(max(Int((time * clip.fps).rounded()), 0), max(clip.frameCount - 1, 0)),
                            to: frame
                        )
                    )
                }
                if let pattern = element.backgroundPattern,
                   let patternCG = LinePattern.image(
                       width: Int(frame.extent.width),
                       height: Int(frame.extent.height),
                       style: pattern,
                       transparentBackground: true
                   ) {
                    content = content.composited(over: CIImage(cgImage: patternCG).cropped(to: frame.extent))
                }
                source = content
            } else {
                LogStore.log("placedImage: clip 帧获取失败 clipID=\(clipID) time=\(time) registered=\(FrameCache.shared.clip(id: clipID) != nil)")
                source = nil
            }
        case .decoration(let decorationID):
            source = decorationRenderer.image(for: decorationID, canvas: canvas)
        case .effect(let effectID):
            source = decorationRenderer.image(for: effectID, canvas: canvas)
        case .text(let textID):
            if let text = composition.texts.first(where: { $0.id.uuidString == textID }) {
                source = textImage(text, maxWidth: canvas.width)
            } else {
                source = nil
            }
        }

        guard let raw = source else { return nil }
        // 滤镜（作用于元素内容，保持 extent 不变）
        let ci: CIImage
        if let filter = element.filter, let name = filter.filterName {
            ci = raw.applyingFilter(name, parameters: [:]).cropped(to: raw.extent)
        } else {
            ci = raw
        }
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

    /// 文字元素渲染：CoreText 排版（自动换行）→ 透明底 CGContext 绘制 → CIImage
    private func textImage(_ text: TextElement, maxWidth: CGFloat) -> CIImage? {
        let font = CTFontCreateWithName((text.fontName ?? "HelveticaNeue-Bold") as CFString, text.fontSize, nil)
        let components = text.colorHex.hexComponents()
        let color = CGColor(red: components.r, green: components.g, blue: components.b, alpha: 1)
        let attributed = NSAttributedString(string: text.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(),
            nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // CoreText 默认 y-up，翻转绘制为像素坐标（与 CGImage 一致）
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
    private func clipFrameImage(clipID: String, at time: TimeInterval) -> CIImage? {
        guard let clip = FrameCache.shared.clip(id: clipID) else { return nil }
        let active = clip.activeFrameIndices
        guard !active.isEmpty else { return nil }
        guard time.isFinite, clip.fps.isFinite, clip.fps > 0 else {
            if let frame = FrameCache.shared.cachedFrame(for: clip, index: active[0]) {
                return CIImage(cgImage: frame)
            }
            return nil
        }
        // 按 activeFrameIndices 顺序播放（视频编辑逻辑：素材播完即结束，不循环）
        let rawIndex = Int((time * clip.fps).rounded())
        // 超出素材时长（排除帧后）→ 素材已结束，不再渲染（元素消失）
        guard rawIndex >= 0, rawIndex < active.count else { return nil }
        let index = active[rawIndex]
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
        fixScale: CGFloat = 1,
        clipID: String = "",
        frameIndex: Int = 0,
        to image: CIImage
    ) -> CIImage {
        // fixScale：预览帧是缩略图时，描边几何（像素绝对值）除以该因子，
        // 保证预览与导出（全分辨率）的描边粗细/虚线几何一致
        let s = max(fixScale, 0.001)
        let color = CIColor(hex: colorHex)
        switch style {
        case .none:
            return image
        case .outline, .whiteOutline, .blackOutline, .goldOutline,
             .outlineSolid, .outlineDashed, .outlineDotted:
            // 组合描边：样式 × 粗细 × 颜色
            return outlined(image, radius: thickness.radius / s, color: color, lineStyle: lineStyle, fixScale: s, clipID: clipID, frameIndex: frameIndex)
        case .glow:
            return glow(image, color: CIColor(hex: "E8C05C"), fixScale: s)
        case .shadow:
            return shadow(image, fixScale: s)
        case .comic:
            let white = outlineLayer(image, radius: 9 / s, color: CIColor(hex: "FFFFFF"), lineStyle: .solid, fixScale: s)
            let black = outlineLayer(image, radius: 3 / s, color: CIColor(hex: "000000"), lineStyle: .solid, fixScale: s)
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
            // 平滑贴纸：仅羽化边缘（边缘带变半透明过渡，内部保持清晰不模糊）。
            // 用模糊后的 alpha 作掩码：内部 alpha≈1 → 原图；边缘 0<alpha<1 → 半透明；外部 → 透明
            let radius = max(1, min(base * 0.012, 6))
            let blurred = image
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: image.extent)
            let clear = CIImage.clear.cropped(to: image.extent)
            return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputMaskImageKey: blurred,
                kCIInputBackgroundImageKey: clear
            ])
        case .customOutline:
            // 自定义描边在主渲染循环直接调用 outlined()（需要边缘参数），此处不会执行
            return image
        }
    }

    private func blurred(_ image: CIImage, radius: CGFloat) -> CIImage {
        image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
    }

    /// 描边：人物在上，描边层垫在下层
    private func outlined(_ image: CIImage, radius: CGFloat, color: CIColor, lineStyle: EdgeLineStyle, fixScale: CGFloat = 1, clipID: String = "", frameIndex: Int = 0) -> CIImage {
        image.composited(over: outlineLayer(image, radius: radius, color: color, lineStyle: lineStyle, fixScale: fixScale, clipID: clipID, frameIndex: frameIndex))
    }

    /// 生成描边层：整图形态学膨胀（alpha 同步外扩）→ 按样式裁切（实线/线段）→ 染成纯色
    private func outlineLayer(_ image: CIImage, radius: CGFloat, color: CIColor, lineStyle: EdgeLineStyle, fixScale: CGFloat = 1, clipID: String = "", frameIndex: Int = 0) -> CIImage {
        let expanded = image.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
        let styled: CIImage
        switch lineStyle {
        case .solid:
            styled = expanded
        case .dashed:
            // 线段（虚线）：沿人物外轮廓跟踪 + 等弧长分段——
            // 空隙沿轮廓曲线方向，段与段之间保持曲线的走势（像素级实现）
            // 掩码按帧缓存：播放/拖动时同帧重复渲染直接命中，不会卡
            let cacheKey = "\(clipID)-\(frameIndex)-\(Int(radius))-\(Int(18 / fixScale))-\(Int(8 / fixScale))"
            if let cached = DashedMaskCache.mask(key: cacheKey) {
                styled = CIImage(cgImage: cached).cropped(to: expanded.extent)
            } else if let dashed = dashedAlongContour(
                expanded,
                segmentLength: 18 / fixScale,
                gapLength: 8 / fixScale,
                cutRadius: radius + 2
            ) {
                if let cg = context.createCGImage(dashed, from: dashed.extent) {
                    DashedMaskCache.store(key: cacheKey, image: cg)
                }
                styled = dashed
            } else {
                styled = expanded
            }
        }
        return tinted(styled, color: color)
    }

    /// 调试：在素材上绘制矩形虚线，验证基础虚线绘制（后续切换为人物轮廓）
    private func dashedAlongContour(
        _ expanded: CIImage, segmentLength: CGFloat, gapLength: CGFloat, cutRadius: CGFloat
    ) -> CIImage? {
        let extent = expanded.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // 矩形虚线（帧内 15% 边距）
        let rect = CGRect(
            x: CGFloat(width) * 0.15, y: CGFloat(height) * 0.15,
            width: CGFloat(width) * 0.7, height: CGFloat(height) * 0.7
        )
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.setLineWidth(cutRadius * 2)
        ctx.setLineDash(phase: 0, lengths: [segmentLength, gapLength])
        ctx.addPath(CGPath(rect: rect, transform: nil))
        ctx.strokePath()
        guard let dashCG = ctx.makeImage() else { return nil }
        let dashCI = CIImage(cgImage: dashCG)
        // 描边层 = expanded × 虚线掩码（虚线处保留、空隙透明）
        let clear = CIImage.clear.cropped(to: extent)
        return expanded.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: dashCI,
            kCIInputBackgroundImageKey: clear
        ])
    }

    /// 折线上弧长 arc 处的点
    private func pointOnPolyline(_ polyline: [CGPoint], cumulative: [CGFloat], arc: CGFloat) -> CGPoint {
        guard polyline.count > 1 else { return polyline.first ?? .zero }
        var low = 0
        var high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] < arc { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return polyline[0] }
        let segStart = polyline[low - 1]
        let segEnd = polyline[low]
        let segLen = cumulative[low] - cumulative[low - 1]
        let t = segLen > 0 ? (arc - cumulative[low - 1]) / segLen : 0
        return CGPoint(
            x: segStart.x + (segEnd.x - segStart.x) * t,
            y: segStart.y + (segEnd.y - segStart.y) * t
        )
    }

    /// Douglas-Peucker 折线简化
    private func simplifyPolyline(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        // 先降采样避免递归过深
        var sampled = points
        if sampled.count > 4000 {
            let step = max(1, sampled.count / 4000)
            sampled = stride(from: 0, to: sampled.count, by: step).map { sampled[$0] }
        }
        func perpendicularDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let abx = b.x - a.x
            let aby = b.y - a.y
            let lengthSq = abx * abx + aby * aby
            guard lengthSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSq))
            let proj = CGPoint(x: a.x + abx * t, y: a.y + aby * t)
            return hypot(p.x - proj.x, p.y - proj.y)
        }
        func dp(_ range: Range<Int>) -> [CGPoint] {
            let a = sampled[range.lowerBound]
            let b = sampled[range.upperBound - 1]
            var maxDist: CGFloat = 0
            var maxIndex = -1
            for i in (range.lowerBound + 1)..<(range.upperBound - 1) {
                let d = perpendicularDistance(sampled[i], a, b)
                if d > maxDist {
                    maxDist = d
                    maxIndex = i
                }
            }
            if maxDist > epsilon && maxIndex > 0 {
                return dp(range.lowerBound..<(maxIndex + 1)).dropLast() + dp(maxIndex..<range.upperBound)
            }
            return [a, b]
        }
        return dp(0..<sampled.count)
    }

    /// 柔光：人物在上，光晕层（膨胀+模糊+染色）垫在下层（光晕不裁剪，避免贴边被截断）
    private func glow(_ image: CIImage, color: CIColor, fixScale: CGFloat = 1) -> CIImage {
        let expanded = image.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 10 / fixScale])
        let blurred = expanded
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 16 / fixScale])
        return image.composited(over: tinted(blurred, color: color))
    }

    /// 投影：先偏移后模糊（对称、不裁剪，避免贴边时阴影被截断）
    private func shadow(_ image: CIImage, fixScale: CGFloat = 1) -> CIImage {
        let mask = image.applyingFilter("CIMaskToAlpha")
        let shifted = mask.transformed(by: CGAffineTransform(
            translationX: 14 / fixScale, y: -14 / fixScale
        ))
        let blurred = shifted
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10 / fixScale])
        return image.composited(over: tinted(blurred, color: CIColor(hex: "000000")))
    }

    /// 用 alpha 掩码染色：纯色 × 人物 alpha（CIBlendWithAlphaMask 使用掩码的
    /// alpha 通道作混合系数，人物外 alpha=0 严格透明，不依赖颜色亮度）
    private func tinted(_ mask: CIImage, color: CIColor) -> CIImage {
        let solid = CIImage(color: color).cropped(to: mask.extent)
        let clear = CIImage.clear.cropped(to: mask.extent)
        return solid.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: clear
        ])
    }
}

// MARK: - 虚线掩码缓存

/// 虚线掩码按帧缓存（key = clipID-帧索引-半径-段长-空隙），播放/拖动时同帧直接命中
private enum DashedMaskCache {
    static let lock = NSLock()
    static var cache: [String: CGImage] = [:]
    static let maxCount = 96

    static func mask(key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    static func store(key: String, image: CGImage) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = image
        if cache.count > maxCount {
            cache.removeAll()
        }
    }
}

// MARK: - 背景线条图案

/// 代码绘制背景线条图案（横线/斜线/网格/马赛克），按参数缓存
private enum LinePattern {
    static let lock = NSLock()
    static var cache: [String: CGImage] = [:]

    static func image(width: Int, height: Int, style: BackgroundPatternStyle, transparentBackground: Bool = false) -> CGImage? {
        let key = "\(width)-\(height)-\(style.pattern.rawValue)-\(Int(style.lineWidth))-\(style.colorHex)-\(Int(style.spacing))-\(Int(style.angle))-\(transparentBackground ? 1 : 0)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let drawn = draw(width: width, height: height, style: style, transparentBackground: transparentBackground) else { return nil }
        lock.lock()
        cache[key] = drawn
        lock.unlock()
        return drawn
    }

    private static func draw(width: Int, height: Int, style: BackgroundPatternStyle, transparentBackground: Bool) -> CGImage? {
        // spacing 异常（0/负数）时回退默认值，避免 stride-by-zero 死循环
        let spacing = style.spacing >= 8 ? style.spacing : 72
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        if !transparentBackground {
            // 浅色底（背景图案模式）
            ctx.setFillColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let lineColor = style.colorHex.hexComponents()
        ctx.setStrokeColor(red: lineColor.r, green: lineColor.g, blue: lineColor.b, alpha: 1)
        ctx.setLineWidth(style.lineWidth)

        switch style.pattern {
        case .horizontal:
            // 线条：按角度绘制平行线族（0 = 横线，45 = 斜线，90 = 竖线…）
            let rad = style.angle * .pi / 180
            let dirX = cos(rad)
            let dirY = sin(rad)
            let nX = -dirY
            let nY = dirX
            let diag = hypot(CGFloat(width), CGFloat(height))
            var offset: CGFloat = -diag
            while offset <= diag {
                let px = CGFloat(width) / 2 + nX * offset
                let py = CGFloat(height) / 2 + nY * offset
                ctx.move(to: CGPoint(x: px - dirX * diag, y: py - dirY * diag))
                ctx.addLine(to: CGPoint(x: px + dirX * diag, y: py + dirY * diag))
                offset += spacing
            }
        case .mosaic:
            // 实心方块与空心方块（仅边框线）间隔的标准棋盘格（无错位、不重叠）。
            // 方块边长由粗细档位（lineWidth）决定
            let cell = max(style.lineWidth, 8)
            ctx.setStrokeColor(red: lineColor.r, green: lineColor.g, blue: lineColor.b, alpha: 1)
            ctx.setLineWidth(2)
            var row = 0
            var y: CGFloat = 0
            while y < CGFloat(height) {
                var col = 0
                var x: CGFloat = 0
                while x < CGFloat(width) {
                    let rect = CGRect(x: x, y: y, width: cell, height: cell)
                    if (col + row) % 2 == 0 {
                        // 实心方块
                        ctx.setFillColor(red: lineColor.r, green: lineColor.g, blue: lineColor.b, alpha: 1)
                        ctx.fill(rect)
                    } else {
                        // 空心方块：只画边框线
                        ctx.stroke(rect)
                    }
                    col += 1
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
    /// hex 颜色字符串拆分为 RGB 分量；非法输入回退为中灰
    fileprivate func hexComponents() -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var hex = trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard hex.count == 6, Scanner(string: hex).scanHexInt64(&value) else {
            return (0.5, 0.5, 0.5)
        }
        return (
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
    }
}

// MARK: - Color

extension CIColor {
    /// 解析 6 位 hex 颜色；非法输入回退为白色，避免静默变黑
    convenience init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard hexString.count == 6, Scanner(string: hexString).scanHexInt64(&value) else {
            self.init(red: 1, green: 1, blue: 1, alpha: 1)
            return
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

