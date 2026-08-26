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
    /// 排除帧的补位方向；倒放预览时使用右侧最近保留帧。
    private let isPlaybackReversed: Bool

    public init(
        context: CIContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]),
        frameMaxPixelSize: CGFloat? = nil,
        isPlaybackReversed: Bool = false
    ) {
        self.context = context
        self.frameMaxPixelSize = frameMaxPixelSize
        self.isPlaybackReversed = isPlaybackReversed
    }

    static func clearSharedCaches() {
        LinePattern.clearCache()
    }

    // MARK: - 输出

    public func render(
        _ composition: Composition,
        at time: TimeInterval
    ) -> CGImage? {
        let playbackTime = composition.compositionPlaybackTime(
            for: time,
            reversed: isPlaybackReversed
        )
        guard let ci = renderCIImage(composition, at: playbackTime) else { return nil }
        let rect = composition.renderRect
        // 预览输出降采样到视口分辨率：先裁到画布区域再缩放，
        // 避免对整图（含画布外元素）缩放时超出区域被填黑
        if let frameMaxPixelSize {
            let size = rect.size
            let scale = min(1, frameMaxPixelSize / max(size.width, size.height))
            if scale < 1 {
                // CI 的 cropped(to:) 会保留原画布坐标。预览分支随后以 (0, 0)
                // 创建 CGImage，若画布已有裁剪偏移就会采到错误区域；导出不缩放，
                // 因此只会在编辑预览中表现为背景层互相“串位”。先归一化再降采样。
                let cropped = ci.cropped(to: rect)
                let normalized = cropped.transformed(by: CGAffineTransform(
                    translationX: -rect.minX,
                    y: -rect.minY
                ))
                let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
                return context.createCGImage(scaled, from: CGRect(origin: .zero, size: scaledSize))
            }
        }
        return context.createCGImage(ci, from: rect)
    }

    public func render(_ composition: Composition, at time: TimeInterval, into pixelBuffer: CVPixelBuffer) -> Bool {
        let playbackTime = composition.compositionPlaybackTime(
            for: time,
            reversed: isPlaybackReversed
        )
        guard let ci = renderCIImage(composition, at: playbackTime) else { return false }
        context.render(ci, to: pixelBuffer, bounds: composition.renderRect, colorSpace: nil)
        return true
    }

    // MARK: - 合成

    func renderCIImage(
        _ composition: Composition,
        at time: TimeInterval
    ) -> CIImage? {
        let canvas = composition.canvasRect
        let baseImage = backgroundCIImage(composition.background, in: canvas)
        // 同一 zIndex 的旧工程也要保持插入顺序，避免 Swift 的不稳定排序导致
        // 重叠元素在播放时层级随机变化，表现为某个元素像是“消失”。
        var orderedElements = composition.elements.enumerated().sorted { lhs, rhs in
            if lhs.element.zIndex != rhs.element.zIndex {
                return lhs.element.zIndex < rhs.element.zIndex
            }
            return lhs.offset < rhs.offset
        }

        // 兼容旧工程：旧版本只保存全局边框样式，没有 canvasEdge 元素。
        // 在渲染时临时补一个置顶元素；编辑器打开工程时会把它持久化到时间轴。
        if composition.canvasEdgeStyle != .none,
           !orderedElements.contains(where: { element in
               if case .canvasEdge = element.element.kind { return true }
               return false
           }) {
            let zIndex = (orderedElements.map { $0.element.zIndex }.max() ?? -1) + 1
            let edge = CompositionElement(
                kind: .canvasEdge,
                name: NSLocalizedString("画布边框", comment: "Canvas edge timeline element"),
                zIndex: zIndex,
                startTime: 0,
                endTime: .greatestFiniteMagnitude
            )
            orderedElements.append((offset: composition.elements.count, element: edge))
            orderedElements.sort { lhs, rhs in
                if lhs.element.zIndex != rhs.element.zIndex {
                    return lhs.element.zIndex < rhs.element.zIndex
                }
                return lhs.offset < rhs.offset
            }
        }

        // 画布边框存在时，底图和普通元素都必须限制在相纸开口内；否则透明
        // 边框 PNG 外的矩形背景会漏出来。这里必须使用“几何开口” mask，
        // 不能使用会扣除边框 alpha 的 canvasContentMaskImage，否则普通元素
        // 永远无法覆盖边框，时间轴排序看起来就不会生效。
        let contentMask: CIImage? = BackgroundMaskRenderer.canvasOpeningMaskImage(
            size: canvas.size,
            style: composition.canvasEdgeStyle
        ).map { CIImage(cgImage: $0).cropped(to: canvas) }

        let canvasEdgeRenderIndex = orderedElements.firstIndex { item in
            if case .canvasEdge = item.element.kind { return true }
            return false
        }

        // 底图永远属于边框下方，先限制在相纸开口内；普通元素则根据它在
        // 边框前/后的实际合成位置决定是否使用开口 mask。
        var image = maskedToCanvasOpening(baseImage, mask: contentMask, canvas: canvas)
        for (renderIndex, item) in orderedElements.enumerated() {
            let element = item.element
            guard element.isVisible(at: time) else { continue }

            if case .canvasEdge = element.kind {
                if let canvasEdge = BackgroundMaskRenderer.canvasEdgeImage(
                    size: canvas.size,
                    style: composition.canvasEdgeStyle,
                    width: composition.canvasEdgeWidth
                ) {
                    image = CIImage(cgImage: canvasEdge)
                        .cropped(to: canvas)
                        .composited(over: image)
                }
                continue
            }

            // 跳过非法变换的元素（NaN/Inf 会导致整个画布渲染失败）
            let t = element.transform
            guard t.position.x.isFinite, t.position.y.isFinite,
                  t.scale.isFinite, t.scale > 0,
                  t.rotation.isFinite else {
                continue
            }
            if let placed = placedImage(
                for: element,
                at: time,
                canvas: canvas,
                composition: composition
            ) {
                // 边框下方的素材不能漏出相纸；边框上方的素材必须允许
                // 覆盖边框和卷角，否则时间轴层级变化在视觉上不会生效。
                let layerIsBelowEdge = canvasEdgeRenderIndex.map { renderIndex < $0 } ?? false
                let layerMask = layerIsBelowEdge ? contentMask : nil
                image = maskedToCanvasOpening(placed, mask: layerMask, canvas: canvas)
                    .composited(over: image)
            }
        }
        // 统一裁剪到画布：任何背景/元素 extent 异常都不会产生未覆盖黑块
        return image.cropped(to: canvas)
    }

    private func maskedToCanvasOpening(
        _ image: CIImage,
        mask: CIImage?,
        canvas: CGRect
    ) -> CIImage {
        guard let mask else { return image }
        let filter = CIFilter(name: "CIBlendWithAlphaMask")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(CIImage.clear.cropped(to: canvas), forKey: kCIInputBackgroundImageKey)
        filter?.setValue(mask, forKey: kCIInputMaskImageKey)
        return filter?.outputImage?.cropped(to: canvas) ?? image
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

    private func placedImage(
        for element: CompositionElement,
        at time: TimeInterval,
        canvas: CGRect,
        composition: Composition
    ) -> CIImage? {
        let source: CIImage?
        var fixScale: CGFloat = 1
        switch element.kind {
        case .canvasEdge:
            source = nil
        case .background(let backgroundID):
            let settings = element.backgroundSettings ?? BackgroundElementSettings()
            if let frame = BackgroundStore.shared.loadFrame(
                named: backgroundID,
                at: max(0, time - element.startTime)
            ) {
                source = backgroundImage(
                    frame,
                    settings: settings,
                    canvas: canvas
                )
            } else {
                source = nil
            }
        case .clip(let clipID):
            if let clip = FrameCache.shared.clip(id: clipID) {
                // 素材内时间：从源素材入点起算，再按素材倍速折算播放位置。
                // 时间轴上的 start/end 只表示当前播放区间，不能再决定素材从第几帧开始。
                let sourceDuration = clip.activeDuration
                let sourceStart = min(max(element.sourceStartTime, 0), sourceDuration)
                let sourceEnd = element.sourceEndTime.isFinite
                    ? min(max(element.sourceEndTime, sourceStart), sourceDuration)
                    : sourceDuration
                let elapsed = max(0, time - element.startTime)
                let sourceCycleDuration = max(
                    (sourceEnd - sourceStart) / max(clip.playbackSpeed, 0.01),
                    0.1
                )
                let isLooping = element.endTime - element.startTime > sourceCycleDuration + 0.001
                // 循环素材的第一次播放可以从裁剪后的入点开始，但循环回绕必须回到
                // 源区间的起点（例如 3,4,5,6,1,2...），不能每轮都从 3 重启。
                let playbackRangeStart = isLooping ? 0 : sourceStart
                let playTime = sourceStart + elapsed * clip.playbackSpeed
                if let frame = clipFrameImage(
                    clipID: clipID,
                    at: playTime,
                    sourceStart: playbackRangeStart,
                    sourceEnd: sourceEnd
                ) {
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
                        clipID: clip.id
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
                    source = nil
                }
            } else {
                source = nil
            }
        case .decoration(let decorationID):
            source = decorationRenderer.image(
                for: decorationID,
                canvas: canvas,
                at: max(0, time - element.startTime),
                duration: element.endTime - element.startTime
            )
        case .effect(let effectID):
            source = decorationRenderer.image(
                for: effectID,
                canvas: canvas,
                at: max(0, time - element.startTime),
                duration: element.endTime - element.startTime
            )
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
        // 背景元素的 transform 由编辑器手势作为“图片在遮罩内的取景”处理，
        // 不能再对已经生成的遮罩整体做一次元素变换，否则会把遮罩区域一起移动。
        if case .background = element.kind {
            return ci
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

    /// 背景媒体元素：先把图片 aspect-fill 到区域，再应用区域遮罩，最后交给通用元素变换。
    private func backgroundImage(
        _ cgImage: CGImage,
        settings: BackgroundElementSettings,
        canvas: CGRect
    ) -> CIImage? {
        // 图片始终先按完整画布尺寸 aspect-fill，区域只负责“露出多少”，
        // 这样上半、下半、对角线、四分之一都不会把原图压缩成区域尺寸。
        let localRect = CGRect(origin: .zero, size: canvas.size)
        let rotatedImage = rotatedBackgroundImage(
            CIImage(cgImage: cgImage),
            quarterTurns: settings.rotationQuarterTurns
        )
        var image = rotatedImage.transformed(by: aspectFillTransform(
            cgImageSize: imageSizeAfterBackgroundRotation(cgImage, quarterTurns: settings.rotationQuarterTurns),
            target: localRect
        ))

        let cropScale = min(max(settings.cropScale.isFinite ? settings.cropScale : 1, 1), 4)
        let center = CGPoint(x: localRect.midX, y: localRect.midY)
        var cropTransform = CGAffineTransform(translationX: center.x, y: center.y)
        cropTransform = cropTransform.scaledBy(x: cropScale, y: cropScale)
        cropTransform = cropTransform.translatedBy(x: -center.x, y: -center.y)
        image = image.transformed(by: cropTransform)
        image = image.transformed(by: CGAffineTransform(
            translationX: settings.cropOffset.x.isFinite ? settings.cropOffset.x : 0,
            y: settings.cropOffset.y.isFinite ? settings.cropOffset.y : 0
        ))

        guard let maskCG = BackgroundMaskRenderer.maskImage(
            size: localRect.size,
            settings: settings
        ) else { return nil }
        let mask = CIImage(cgImage: maskCG).cropped(to: localRect)
        // 遮罩图是透明 RGBA 位图：分区外部的 RGB 值不属于遮罩语义，只有 alpha
        // 才表示该背景元素应当露出的区域。`CIBlendWithMask` 会读取颜色亮度，多个
        // 分区背景叠加时可能把透明像素的颜色也作为遮罩参与计算，造成所有图层像是
        // 落在同一个分区。明确使用 alpha 遮罩，预览和导出都会按每个元素各自的
        // selectedPartition 合成。
        let filter = CIFilter(name: "CIBlendWithAlphaMask")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(CIImage.clear.cropped(to: localRect), forKey: kCIInputBackgroundImageKey)
        filter?.setValue(mask, forKey: kCIInputMaskImageKey)
        guard var output = filter?.outputImage?.cropped(to: localRect) else { return nil }

        if let edgeCG = BackgroundMaskRenderer.edgeImage(
            size: localRect.size,
            settings: settings
        ) {
            output = CIImage(cgImage: edgeCG).cropped(to: localRect).composited(over: output)
        }

        return output.transformed(by: CGAffineTransform(
            translationX: canvas.minX,
            y: canvas.minY
        ))
    }

    /// Core Image 使用 y-up 坐标，正 90° 会对应界面里的顺时针旋转。
    private func rotatedBackgroundImage(_ image: CIImage, quarterTurns: Int) -> CIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2))
        return rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX,
            y: -rotated.extent.minY
        ))
    }

    private func imageSizeAfterBackgroundRotation(_ image: CGImage, quarterTurns: Int) -> CGSize {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns % 2 == 1 {
            return CGSize(width: image.height, height: image.width)
        }
        return CGSize(width: image.width, height: image.height)
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
    private func clipFrameImage(
        clipID: String,
        at time: TimeInterval,
        sourceStart: TimeInterval = 0,
        sourceEnd: TimeInterval? = nil
    ) -> CIImage? {
        guard let clip = FrameCache.shared.clip(id: clipID) else { return nil }
        let playbackFrames = clip.playbackFrameIndices(reversed: isPlaybackReversed)
        guard !playbackFrames.isEmpty else { return nil }
        let fps = clip.fps
        guard fps.isFinite, fps > 0 else {
            if let frame = FrameCache.shared.cachedFrame(for: clip, index: playbackFrames[0]) {
                return CIImage(cgImage: frame)
            }
            return nil
        }
        let sourceDuration = max(clip.activeDuration, 0)
        let boundedStart = min(max(sourceStart.isFinite ? sourceStart : 0, 0), sourceDuration)
        let boundedEnd = min(
            max(sourceEnd?.isFinite == true ? sourceEnd! : sourceDuration, boundedStart),
            sourceDuration
        )
        let startIndex = min(
            max(Int((boundedStart * fps).rounded(.down)), 0),
            playbackFrames.count - 1
        )
        let endIndex = min(
            max(Int((boundedEnd * fps).rounded(.up)), startIndex + 1),
            playbackFrames.count
        )
        let cycleFrameCount = max(endIndex - startIndex, 1)
        guard time.isFinite else {
            if let frame = FrameCache.shared.cachedFrame(for: clip, index: playbackFrames[startIndex]) {
                return CIImage(cgImage: frame)
            }
            return nil
        }
        // 素材条延长后按当前源入点/出点循环，不再在源素材末尾显示空白。
        // 帧编辑产生的 playbackFrames 仍然保留原有补位结果，因此循环不会破坏帧编辑语义。
        let relativeFrame = max(Int(((time - boundedStart) * fps).rounded(.down)), 0)
        let index = playbackFrames[startIndex + (relativeFrame % cycleFrameCount)]
        let frame: CGImage?
        if let frameMaxPixelSize {
            frame = FrameCache.shared.cachedThumbnail(
                for: clip,
                index: index,
                maxPixelSize: frameMaxPixelSize
            )
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

    /// 生成描边层：整图形态学膨胀（alpha 同步外扩）→ 染成纯色。
    /// 统一用实线算法（线段未实现的调试代码已移除）
    private func outlineLayer(_ image: CIImage, radius: CGFloat, color: CIColor, lineStyle: EdgeLineStyle, fixScale: CGFloat = 1, clipID: String = "", frameIndex: Int = 0) -> CIImage {
        let expanded = image.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
        return tinted(expanded, color: color)
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

// MARK: - 背景线条图案

/// 代码绘制背景线条图案（横线/斜线/网格/马赛克），按参数缓存
private enum LinePattern {
    static let lock = NSLock()
    static var cache: [String: CGImage] = [:]

    static func clearCache() {
        lock.lock()
        cache.removeAll(keepingCapacity: false)
        lock.unlock()
    }

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
