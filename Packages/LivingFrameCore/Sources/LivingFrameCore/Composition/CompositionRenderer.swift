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
    /// Whether clip-level edge and sticker effects should be applied.
    private let appliesClipEffects: Bool
    /// 仅用于最终导出，编辑预览不传入该值。
    private let exportWatermark: ExportWatermark?
    /// 背景素材的读取入口由调用方提供，避免渲染器把磁盘存储和渲染逻辑绑在一起。
    private let backgroundMediaProvider: any BackgroundMediaProviding

    public init(
        context: CIContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]),
        frameMaxPixelSize: CGFloat? = nil,
        isPlaybackReversed: Bool = false,
        appliesClipEffects: Bool = true,
        exportWatermark: ExportWatermark? = nil,
        backgroundMediaProvider: any BackgroundMediaProviding
    ) {
        self.context = context
        self.frameMaxPixelSize = frameMaxPixelSize
        self.isPlaybackReversed = isPlaybackReversed
        self.appliesClipEffects = appliesClipEffects
        self.exportWatermark = exportWatermark
        self.backgroundMediaProvider = backgroundMediaProvider
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

    public func render(
        _ composition: Composition,
        at time: TimeInterval,
        into pixelBuffer: CVPixelBuffer,
        outputSize: CGSize? = nil
    ) -> Bool {
        let playbackTime = composition.compositionPlaybackTime(
            for: time,
            reversed: isPlaybackReversed
        )
        guard let ci = renderCIImage(composition, at: playbackTime) else { return false }
        let sourceRect = composition.renderRect
        let targetSize = outputSize ?? sourceRect.size
        if targetSize != sourceRect.size {
            // Pixel buffer 的尺寸可能小于工程画布。先裁成画布、归一化到零原点，再等比
            // 缩放到目标尺寸，避免 CIContext 直接渲染时发生错位或裁切。
            let normalized = ci.cropped(to: sourceRect).transformed(by: CGAffineTransform(
                translationX: -sourceRect.minX,
                y: -sourceRect.minY
            ))
            let scaled = normalized.transformed(by: CGAffineTransform(
                scaleX: targetSize.width / sourceRect.width,
                y: targetSize.height / sourceRect.height
            ))
            context.render(scaled, to: pixelBuffer,
                           bounds: CGRect(origin: .zero, size: targetSize), colorSpace: nil)
        } else {
            context.render(ci, to: pixelBuffer, bounds: sourceRect, colorSpace: nil)
        }
        return true
    }

    /// Renders a small style-option sample using the same clip-effect pipeline as
    /// composition preview and export. The source frame is decoded at thumbnail size.
    public func stickerStyleThumbnail(
        for clip: SegmentedClip,
        frameIndex: Int,
        style: StickerStyle,
        maxPixelSize: CGFloat = 144
    ) -> CGImage? {
        guard clip.frameCount > 0, maxPixelSize.isFinite, maxPixelSize > 0 else { return nil }
        let boundedIndex = min(max(frameIndex, 0), clip.frameCount - 1)
        guard let preview = normalizedClipOptionPreviewFrame(
            for: clip,
            frameIndex: boundedIndex,
            maxPixelSize: maxPixelSize
        ) else {
            return nil
        }

        let fixScale = optionPreviewFixScale(clip: clip, preview: preview)
        let styled = applyClipStyle(
            style,
            clip: clip,
            fixScale: fixScale,
            subjectBounds: preview.subjectBounds,
            to: preview.image
        )
        let outputRect = preview.image.extent.integral
        guard let rendered = context.createCGImage(styled.cropped(to: outputRect), from: outputRect) else {
            return nil
        }
        return rendered
    }

    /// Resolves the source frame displayed by both style and filter option previews.
    /// Keeping this mapping shared prevents preview rows from showing different poses
    /// (and therefore appearing to use different zoom) while the playhead moves.
    public static func optionPreviewFrameIndex(
        for element: CompositionElement,
        in composition: Composition,
        at time: TimeInterval,
        reversed: Bool = false
    ) -> Int? {
        guard case .clip(let clipID) = element.kind,
              let clip = FrameCache.shared.clip(id: clipID) else {
            return nil
        }

        let playbackFrames = clip.playbackFrameIndices(reversed: reversed)
        guard !playbackFrames.isEmpty else { return nil }
        let clipFPS = clip.fps
        guard clipFPS.isFinite, clipFPS > 0 else { return playbackFrames.first }

        let compositionFPS = composition.fps.isFinite && composition.fps > 0 ? composition.fps : 30
        let frameDuration = 1 / compositionFPS
        let rawDuration = element.endTime - element.startTime
        let duration = rawDuration.isFinite ? max(rawDuration, frameDuration) : frameDuration
        let elapsed = time.isFinite ? max(time - element.startTime, 0) : 0
        let sampleTime = min(elapsed, max(duration - frameDuration, 0))

        let sourceRange = SourcePlaybackRange(
            duration: clip.playbackSourceDuration,
            start: element.sourceStartTime,
            end: element.sourceEndTime
        )
        let cycleDuration = sourceRange.span / max(clip.playbackSpeed, 0.01)
        let sourceTime = sourceRange.sourceTime(
            at: sampleTime,
            playbackRate: clip.playbackSpeed,
            phase: element.sourcePlaybackOffset ?? 0,
            looping: element.shouldLoop(cycleDuration: cycleDuration)
        )

        let startIndex = min(
            max(Int((sourceRange.start * clipFPS).rounded(.down)), 0),
            playbackFrames.count - 1
        )
        let endIndex = min(
            max(Int((sourceRange.end * clipFPS).rounded(.up)), startIndex + 1),
            playbackFrames.count
        )
        let cycleFrameCount = max(endIndex - startIndex, 1)
        let relativeFrame = max(Int(((sourceTime - sourceRange.start) * clipFPS).rounded(.down)), 0)
        return playbackFrames[startIndex + (relativeFrame % cycleFrameCount)]
    }

    /// Renders one isolated element with a candidate filter, then normalizes its
    /// unfiltered content into the same option-tile framing for every filter.
    public func elementFilterThumbnail(
        for element: CompositionElement,
        in composition: Composition,
        at time: TimeInterval,
        filter: ElementFilter,
        maxPixelSize: CGFloat = 144
    ) -> CGImage? {
        guard maxPixelSize.isFinite, maxPixelSize > 0,
              composition.elements.contains(where: { $0.id == element.id }) else {
            return nil
        }

        if case .clip(let clipID) = element.kind,
           let clip = FrameCache.shared.clip(id: clipID),
           let frameIndex = Self.optionPreviewFrameIndex(
                for: element,
                in: composition,
                at: time,
                reversed: isPlaybackReversed
           ),
           let preview = normalizedClipOptionPreviewFrame(
                for: clip,
                frameIndex: frameIndex,
                maxPixelSize: maxPixelSize
           ) {
            // Normalize the raw cutout first, exactly as the style picker does.
            // Then composite the element's current effects and apply the candidate
            // filter, so existing outlines cannot change the zoom estimate.
            let fixScale = optionPreviewFixScale(clip: clip, preview: preview)
            var source = applyClipStyle(
                clip.stickerStyle,
                clip: clip,
                fixScale: fixScale,
                subjectBounds: preview.subjectBounds,
                to: preview.image
            )
            let filtered = applyingElementFilter(filter, to: source)
            let outputRect = preview.image.extent.integral
            return context.createCGImage(filtered.cropped(to: outputRect), from: outputRect)
        }

        let fps = composition.fps.isFinite && composition.fps > 0 ? composition.fps : 30
        let frameDuration = 1 / fps
        let elementDuration = element.endTime - element.startTime
        let duration = elementDuration.isFinite ? max(elementDuration, frameDuration) : frameDuration
        let elapsed = time.isFinite ? max(time - element.startTime, 0) : 0
        let sampleTime = min(elapsed, max(duration - frameDuration, 0))

        var previewElement = element
        previewElement.startTime = 0
        previewElement.endTime = duration
        previewElement.transform = ElementTransform(
            position: CGPoint(x: composition.canvas.width / 2, y: composition.canvas.height / 2)
        )
        previewElement.filter = nil

        var previewComposition = composition
        previewComposition.duration = duration
        previewComposition.elements = [previewElement]
        previewComposition.audioClips = []
        previewComposition.background = .clear
        previewComposition.canvasEdgeStyle = .none
        previewComposition.cropRect = nil
        previewComposition.excludedCompositionFrames = []

        let previewRenderer = CompositionRenderer(
            context: context,
            frameMaxPixelSize: maxPixelSize,
            isPlaybackReversed: false,
            appliesClipEffects: false,
            backgroundMediaProvider: backgroundMediaProvider
        )
        guard let source = previewRenderer.render(previewComposition, at: sampleTime),
              let normalized = normalizedOptionPreviewFrame(
                from: source,
                maxPixelSize: Int(maxPixelSize.rounded())
              ) else {
            return nil
        }

        let filtered = applyingElementFilter(filter, to: normalized.image)
        let outputRect = normalized.image.extent.integral
        return context.createCGImage(filtered.cropped(to: outputRect), from: outputRect)
    }

    private func normalizedClipOptionPreviewFrame(
        for clip: SegmentedClip,
        frameIndex: Int,
        maxPixelSize: CGFloat
    ) -> (sourceImage: CGImage, image: CIImage, sourceScale: CGFloat, subjectBounds: CGRect)? {
        guard let thumbnail = FrameCache.shared.cachedThumbnail(
            for: clip,
            index: frameIndex,
            maxPixelSize: maxPixelSize
        ) else {
            return nil
        }

        // cachedThumbnail already applies the crop; rotate before measuring the
        // subject, then use the same normalized canvas and zoom for both pickers.
        let frame = rotatedClipImage(
            CIImage(cgImage: thumbnail),
            quarterTurns: clip.normalizedRotationQuarterTurns
        )
        let sourceRect = frame.extent.integral
        guard let sourceImage = context.createCGImage(frame.cropped(to: sourceRect), from: sourceRect),
              let normalized = normalizedOptionPreviewFrame(
                from: sourceImage,
                maxPixelSize: Int(maxPixelSize.rounded())
              ) else {
            return nil
        }
        return (sourceImage, normalized.image, normalized.sourceScale, normalized.subjectBounds)
    }

    private func optionPreviewFixScale(
        clip: SegmentedClip,
        preview: (sourceImage: CGImage, image: CIImage, sourceScale: CGFloat, subjectBounds: CGRect)
    ) -> CGFloat {
        let outputWidth = CGFloat(max(clip.renderedWidth, 1))
        return max(
            outputWidth / max(CGFloat(preview.sourceImage.width) * preview.sourceScale, 1),
            4
        )
    }

    /// Fits the source subject into a shared thumbnail canvas before effects are
    /// rendered. Unlike trimming each styled result independently, this makes the
    /// cutout's scale and center identical for every style option.
    private func normalizedOptionPreviewFrame(
        from image: CGImage,
        maxPixelSize: Int
    ) -> (image: CIImage, sourceScale: CGFloat, subjectBounds: CGRect)? {
        guard maxPixelSize > 0 else { return nil }
        let width = maxPixelSize
        // Matches both style and filter wells' usable aspect ratio (58×46 after padding).
        let height = max(Int((CGFloat(width) * 46 / 58).rounded()), 1)
        let bounds = AlphaSubjectBounds.visiblePixelBounds(in: image)
            ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sourceBounds = bounds.integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard sourceBounds.width > 0, sourceBounds.height > 0,
              let subject = image.cropping(to: sourceBounds) else {
            return nil
        }

        // Zoom the subject substantially while preserving room for outlines/glows.
        let fillRatio: CGFloat = 0.88
        let scale = min(
            CGFloat(width) * fillRatio / CGFloat(subject.width),
            CGFloat(height) * fillRatio / CGFloat(subject.height)
        )
        let drawSize = CGSize(
            width: CGFloat(subject.width) * scale,
            height: CGFloat(subject.height) * scale
        )
        let destination = CGRect(
            x: (CGFloat(width) - drawSize.width) / 2,
            y: (CGFloat(height) - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        guard let bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.interpolationQuality = .high
        bitmap.draw(subject, in: destination)
        guard let normalized = bitmap.makeImage() else { return nil }
        return (CIImage(cgImage: normalized), scale, destination)
    }

    /// Returns the complete untransformed rectangle of the content rendered for
    /// an element at the given time. The element transform is intentionally
    /// neutralized so the editor can apply one shared transform/viewport mapping
    /// to both the content and its selection frame.
    public func contentSize(
        for element: CompositionElement,
        in composition: Composition,
        at time: TimeInterval
    ) -> CGSize? {
        if case .collage = element.kind {
            return composition.canvasRect.size
        }
        if element.faceStickerTracking != nil,
           case .decoration(let decorationID) = element.kind,
           let image = decorationRenderer.image(
                for: decorationID,
                canvas: composition.canvasRect,
                at: max(0, time - element.startTime),
                duration: element.endTime - element.startTime,
                sourceStartTime: element.sourceStartTime,
                sourceEndTime: element.sourceEndTime,
                playbackOffsetTime: element.sourcePlaybackOffset ?? 0,
                playbackCount: element.playbackCount,
                faceYaw: trackedFaceStickerKeyframe(for: element, in: composition, at: time)?.yaw,
                facePitch: trackedFaceStickerKeyframe(for: element, in: composition, at: time)?.pitch
           ) {
            return image.extent.standardized.size
        }

        // 素材的选中框代表“素材画布”而不是当前帧的非透明像素范围。
        // 分割结果的透明边缘、描边和滤镜会随帧变化，不能让它们改变交互边界。
        if case .clip(let clipID) = element.kind,
           let clip = FrameCache.shared.clip(id: clipID) {
            return CGSize(
                width: max(clip.renderedWidth, 1),
                height: max(clip.renderedHeight, 1)
            )
        }

        var neutralElement = element
        neutralElement.transform = ElementTransform(
            position: .zero,
            scale: 1,
            rotation: 0
        )
        guard let image = placedImage(
            for: neutralElement,
            at: time,
            canvas: composition.canvasRect,
            composition: composition
        ) else {
            return nil
        }
        let size = image.extent.standardized.size
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0 else {
            return nil
        }
        return size
    }

    /// Visible-art bounds for sticker selection frames, in the original sticker
    /// image's lower-left coordinate space. The interaction still transforms the
    /// full image canvas; only the visual selection affordance trims transparent
    /// padding around the sticker artwork.
    public func stickerSelectionBounds(for element: CompositionElement) -> CGRect? {
        guard case .decoration(let decorationID) = element.kind,
              decorationID.hasPrefix("sticker-") else {
            return nil
        }
        return decorationRenderer.selectionBounds(for: decorationID)
    }

    /// Transform used by the canvas selection frame. Face stickers resolve this
    /// from the same source frame and landmarks as the rendered image.
    public func resolvedTransform(
        for element: CompositionElement,
        in composition: Composition,
        at time: TimeInterval
    ) -> ElementTransform {
        guard element.faceStickerTracking != nil,
              case .decoration(let decorationID) = element.kind,
              let image = decorationRenderer.image(
                for: decorationID,
                canvas: composition.canvasRect,
                at: max(0, time - element.startTime),
                duration: element.endTime - element.startTime,
                sourceStartTime: element.sourceStartTime,
                sourceEndTime: element.sourceEndTime,
                playbackOffsetTime: element.sourcePlaybackOffset ?? 0,
                playbackCount: element.playbackCount,
                faceYaw: trackedFaceStickerKeyframe(for: element, in: composition, at: time)?.yaw,
                facePitch: trackedFaceStickerKeyframe(for: element, in: composition, at: time)?.pitch
              ),
              let transform = faceStickerTransform(
                for: element,
                in: composition,
                at: time,
                stickerSize: image.extent.standardized.size
              ) else {
            return element.transform
        }
        return transform
    }

    // MARK: - 合成

    func renderCIImage(
        _ composition: Composition,
        at time: TimeInterval
    ) -> CIImage? {
        let canvas = composition.canvasRect
        let baseImage = backgroundCIImage(composition.background, in: canvas)
        // 同一 zIndex 保持插入顺序，避免 Swift 的不稳定排序导致
        // 重叠元素在播放时层级随机变化，表现为某个元素像是“消失”。
        let orderedElements = composition.elements.enumerated().sorted { lhs, rhs in
            if lhs.element.zIndex != rhs.element.zIndex {
                return lhs.element.zIndex < rhs.element.zIndex
            }
            return lhs.offset < rhs.offset
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

            // 外层拼接容器负责把整个拼接作为一个图层输出；容器存在时，
            // 组内素材不能再作为普通画布图层单独合成。
            if let childGroupID = element.collageGroupID,
               composition.elements.contains(where: {
                   if case .collage(let collageID) = $0.kind {
                       return collageID == childGroupID
                   }
                   return false
               }) {
                continue
            }

            if case .canvasEdge = element.kind {
                if let canvasEdge = BackgroundMaskRenderer.canvasEdgeImage(
                    size: canvas.size,
                    style: composition.canvasEdgeStyle
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
        if let exportWatermark {
            image = watermarkImage(exportWatermark, canvas: canvas, at: time)
                .composited(over: image)
        }
        // 统一裁剪到画布：任何背景/元素 extent 异常都不会产生未覆盖黑块
        return image.cropped(to: canvas)
    }

    private func watermarkImage(
        _ watermark: ExportWatermark,
        canvas: CGRect,
        at time: TimeInterval
    ) -> CIImage {
        guard let source = decorationRenderer.image(
            for: watermark.decorationID,
            canvas: canvas,
            at: time,
            duration: .greatestFiniteMagnitude
        ) else {
            return CIImage.clear.cropped(to: canvas)
        }

        let sourceExtent = source.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else {
            return CIImage.clear.cropped(to: canvas)
        }
        let shortSide = min(canvas.width, canvas.height)
        let targetWidth = max(shortSide * 0.48, 1)
        let scale = targetWidth / sourceExtent.width
        let trailingInset = max(canvas.width * 0.10, 1)
        let bottomInset = max(canvas.height * 0.10, 1)
        let transformed = source
            .transformed(by: CGAffineTransform(translationX: -sourceExtent.minX, y: -sourceExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: canvas.maxX - trailingInset - targetWidth,
                y: canvas.minY + bottomInset
            ))
        return transformed.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: watermark.opacity)
        ])
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
            let sourceDuration = max(
                backgroundMediaProvider.media(named: backgroundID)?.duration ?? 0.1,
                0.1
            )
            let sourceRange = SourcePlaybackRange(
                duration: sourceDuration,
                start: element.sourceStartTime,
                end: element.sourceEndTime
            )
            let elapsed = max(0, time - element.startTime)
            let sourceTime = sourceRange.sourceTime(
                at: elapsed,
                phase: element.sourcePlaybackOffset ?? 0,
                looping: element.shouldLoop(cycleDuration: sourceRange.span)
            )
            if let frame = backgroundMediaProvider.loadFrame(
                named: backgroundID,
                at: sourceTime
            ) {
                if element.collageGroupID == nil {
                    source = standaloneBackgroundImage(frame, settings: settings)
                } else {
                    source = backgroundImage(
                        frame,
                        settings: settings,
                        canvas: canvas
                    )
                }
            } else {
                source = nil
            }
        case .collage(let groupID):
            source = collageGroupImage(
                groupID: groupID,
                at: time,
                canvas: canvas,
                composition: composition
            )
        case .clip(let clipID):
            if let clip = FrameCache.shared.clip(id: clipID) {
                // 素材内时间：从源素材入点起算，再按素材倍速折算播放位置。
                // 时间轴上的 start/end 只表示当前播放区间，不能再决定素材从第几帧开始。
                let sourceDuration = clip.playbackSourceDuration
                let sourceRange = SourcePlaybackRange(
                    duration: sourceDuration,
                    start: element.sourceStartTime,
                    end: element.sourceEndTime
                )
                let elapsed = max(0, time - element.startTime)
                let sourceCycleDuration = max(
                    sourceRange.span / max(clip.playbackSpeed, 0.01),
                    0.001
                )
                let isLooping = element.shouldLoop(cycleDuration: sourceCycleDuration)
                let playTime = sourceRange.sourceTime(
                    at: elapsed,
                    playbackRate: clip.playbackSpeed,
                    phase: element.sourcePlaybackOffset ?? 0,
                    looping: isLooping
                )
                if let renderedFrame = clipFrameImage(
                    clipID: clipID,
                    at: playTime,
                    sourceStart: sourceRange.start,
                    sourceEnd: sourceRange.end
                ) {
                let frame = renderedFrame.image
                // 预览用缩略图（尺寸 < 素材实际像素）。不把源图放大回全尺寸——
                // 放大插值会在人物边缘产生半透明残留像素（贴边时形成"阴影线"）。
                // 改为把归一化因子并入元素缩放，源图始终一次缩放到位。
                let targetWidth = CGFloat(max(clip.renderedWidth, 1))
                fixScale = targetWidth > 0 && Int(frame.extent.width) > 0
                    ? targetWidth / frame.extent.width
                    : 1
                var content = appliesClipEffects
                    ? applyClipStyle(
                        clip.stickerStyle,
                        clip: clip,
                        fixScale: fixScale,
                        subjectBounds: renderedFrame.subjectBounds,
                        to: frame
                    )
                    : frame
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
                duration: element.endTime - element.startTime,
                sourceStartTime: element.sourceStartTime,
                sourceEndTime: element.sourceEndTime,
                playbackOffsetTime: element.sourcePlaybackOffset ?? 0,
                playbackCount: element.playbackCount,
                faceYaw: trackedFaceStickerKeyframe(for: element, in: composition, at: time)?.yaw,
                facePitch: trackedFaceStickerKeyframe(for: element, in: composition, at: time)?.pitch
            )
        case .effect(let effectID):
            source = decorationRenderer.image(
                for: effectID,
                canvas: canvas,
                at: max(0, time - element.startTime),
                duration: element.endTime - element.startTime,
                sourceStartTime: element.sourceStartTime,
                sourceEndTime: element.sourceEndTime,
                playbackOffsetTime: element.sourcePlaybackOffset ?? 0,
                playbackCount: element.playbackCount
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
        let ci = applyingElementFilter(element.filter, to: raw)
        // 拼接背景的 transform 由编辑器手势作为“图片在遮罩内的取景”处理，
        // 不能再对已经生成的遮罩整体做一次元素变换。独立照片则像普通素材一样
        // 使用 element.transform 参与位置、缩放和旋转。
        if case .background = element.kind,
           element.collageGroupID != nil {
            return ci
        }
        let elementTransform: ElementTransform
        if element.faceStickerTracking != nil {
            guard let trackingTransform = faceStickerTransform(
                for: element,
                in: composition,
                at: time,
                stickerSize: ci.extent.standardized.size
            ) else {
                return nil
            }
            elementTransform = trackingTransform
        } else {
            elementTransform = element.transform
        }
        // CGAffineTransform 链为右乘：新变换先应用。
        // 目标应用顺序：平移到元素中心(-mid) → 缩放 → 旋转 → 平移到目标位置(position)。
        // 因此矩阵必须从"最后应用"的变换开始构造。
        // fixScale 把缩略图尺寸换算到素材实际像素尺寸，保证元素渲染尺寸与全尺寸一致。
        let effectiveScale = elementTransform.scale * fixScale
        var transform = CGAffineTransform(
            translationX: elementTransform.position.x,
            y: elementTransform.position.y
        )
        transform = transform.rotated(by: elementTransform.rotation)
        transform = transform.scaledBy(x: effectiveScale, y: effectiveScale)
        transform = transform.translatedBy(x: -ci.extent.midX, y: -ci.extent.midY)
        return ci.transformed(by: transform)
    }

    /// 将同一拼接组的内部素材合成为透明画布，供外层拼接容器作为一个普通元素使用。
    private func collageGroupImage(
        groupID: UUID,
        at time: TimeInterval,
        canvas: CGRect,
        composition: Composition
    ) -> CIImage? {
        let children = composition.elements
            .filter { element in
                guard case .background = element.kind,
                      let childGroupID = element.collageGroupID else { return false }
                return childGroupID == groupID && element.isVisible(at: time)
            }
            .sorted {
                if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
                return $0.id.uuidString < $1.id.uuidString
            }
        guard !children.isEmpty else { return nil }

        var image = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        ).cropped(to: canvas)
        for child in children {
            guard let childImage = placedImage(
                for: child,
                at: time,
                canvas: canvas,
                composition: composition
            ) else { continue }
            image = childImage.composited(over: image)
        }
        return image
    }

    private func faceStickerTransform(
        for element: CompositionElement,
        in composition: Composition,
        at time: TimeInterval,
        stickerSize: CGSize
    ) -> ElementTransform? {
        guard let tracking = element.faceStickerTracking,
              case .decoration(let decorationID) = element.kind,
              let definition = DecorationRenderer.stickerDefinition(for: decorationID),
              let keyframe = trackedFaceStickerKeyframe(for: element, in: composition, at: time),
              let targetElement = composition.elements.first(where: { $0.id == tracking.targetClipElementID }),
              case .clip(let clipID) = targetElement.kind,
              clipID == tracking.clipID,
              let clip = FrameCache.shared.clip(id: clipID),
              targetElement.isVisible(at: time) else {
            return nil
        }

        let frameSize = CGSize(
            width: CGFloat(max(clip.renderedWidth, 1)),
            height: CGFloat(max(clip.renderedHeight, 1))
        )

        func placement(for sample: FaceStickerKeyframe, scaleOverride: CGFloat? = nil) -> ElementTransform? {
            guard let anchors = DecorationRenderer.faceViewSelection(
                for: decorationID,
                yaw: sample.yaw,
                pitch: sample.pitch
            )?
                .anchors(for: definition.renderingMode)
                ?? definition.faceAnchors else {
                return nil
            }
            return FaceStickerPlacement.transform(
                for: sample,
                frameSize: frameSize,
                clipTransform: targetElement.transform,
                stickerSize: stickerSize,
                stickerAnchors: anchors,
                userOffset: element.transform,
                scaleOverride: scaleOverride
            )
        }

        guard let current = placement(for: keyframe) else { return nil }
        let previousScale = tracking.keyframe(at: keyframe.frameIndex - 1)
            .flatMap { placement(for: $0)?.scale } ?? current.scale
        let nextScale = tracking.keyframe(at: keyframe.frameIndex + 1)
            .flatMap { placement(for: $0)?.scale } ?? current.scale
        let stableScale = FaceStickerPlacement.smoothedScale(
            previous: previousScale,
            current: current.scale,
            next: nextScale
        )
        return placement(for: keyframe, scaleOverride: stableScale) ?? current
    }

    private func trackedFaceStickerKeyframe(
        for element: CompositionElement,
        in composition: Composition,
        at time: TimeInterval
    ) -> FaceStickerKeyframe? {
        guard let tracking = element.faceStickerTracking,
              let targetElement = composition.elements.first(where: { $0.id == tracking.targetClipElementID }),
              targetElement.isVisible(at: time),
              case .clip(let clipID) = targetElement.kind,
              clipID == tracking.clipID,
              let clip = FrameCache.shared.clip(id: clipID),
              let sourceFrameIndex = trackedSourceFrameIndex(for: targetElement, clip: clip, at: time) else {
            return nil
        }
        return tracking.keyframe(at: sourceFrameIndex)
    }

    private func trackedSourceFrameIndex(
        for element: CompositionElement,
        clip: SegmentedClip,
        at compositionTime: TimeInterval
    ) -> Int? {
        let sourceRange = SourcePlaybackRange(
            duration: clip.playbackSourceDuration,
            start: element.sourceStartTime,
            end: element.sourceEndTime
        )
        let elapsed = max(0, compositionTime - element.startTime)
        let cycleDuration = max(sourceRange.span / max(clip.playbackSpeed, 0.01), 0.001)
        let sourceTime = sourceRange.sourceTime(
            at: elapsed,
            playbackRate: clip.playbackSpeed,
            phase: element.sourcePlaybackOffset ?? 0,
            looping: element.shouldLoop(cycleDuration: cycleDuration)
        )

        let playbackFrames = clip.playbackFrameIndices(reversed: isPlaybackReversed)
        guard !playbackFrames.isEmpty else { return nil }
        let fps = clip.fps
        guard fps.isFinite, fps > 0 else { return playbackFrames.first }

        let boundedStart = min(max(sourceRange.start, 0), clip.playbackSourceDuration)
        let boundedEnd = min(max(sourceRange.end, boundedStart), clip.playbackSourceDuration)
        let startIndex = min(
            max(Int((boundedStart * fps).rounded(.down)), 0),
            playbackFrames.count - 1
        )
        let endIndex = min(
            max(Int((boundedEnd * fps).rounded(.up)), startIndex + 1),
            playbackFrames.count
        )
        let cycleFrameCount = max(endIndex - startIndex, 1)
        let relativeFrame = max(Int(((sourceTime - boundedStart) * fps).rounded(.down)), 0)
        return playbackFrames[startIndex + (relativeFrame % cycleFrameCount)]
    }

    private func applyingElementFilter(_ filter: ElementFilter?, to image: CIImage) -> CIImage {
        guard let name = filter?.filterName else { return image }
        return image.applyingFilter(name, parameters: [:]).cropped(to: image.extent)
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

        let cropScale = min(
            max(
                settings.cropScale.isFinite ? settings.cropScale : 1,
                BackgroundElementSettings.minimumCropScale
            ),
            BackgroundElementSettings.maximumCropScale
        )
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

    /// 独立相册照片不使用拼接遮罩，保留原始图片矩形交给普通元素变换处理。
    private func standaloneBackgroundImage(
        _ cgImage: CGImage,
        settings: BackgroundElementSettings
    ) -> CIImage {
        var image = rotatedBackgroundImage(
            CIImage(cgImage: cgImage),
            quarterTurns: settings.rotationQuarterTurns
        )
        let extent = image.extent.standardized
        let cropScale = min(
            max(
                settings.cropScale.isFinite ? settings.cropScale : 1,
                BackgroundElementSettings.minimumCropScale
            ),
            BackgroundElementSettings.maximumCropScale
        )
        let center = CGPoint(x: extent.midX, y: extent.midY)
        var cropTransform = CGAffineTransform(translationX: center.x, y: center.y)
        cropTransform = cropTransform.scaledBy(x: cropScale, y: cropScale)
        cropTransform = cropTransform.translatedBy(x: -center.x, y: -center.y)
        image = image.transformed(by: cropTransform)
        image = image.transformed(by: CGAffineTransform(
            translationX: settings.cropOffset.x,
            y: settings.cropOffset.y
        ))
        return image
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
        let size = TextLayout.measuredSize(for: text, maxWidth: maxWidth)
        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.textMatrix = .identity
        TextLayout.draw(
            text,
            in: ctx,
            maxWidth: maxWidth,
            size: CGSize(width: width, height: height)
        )
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
    private struct RenderedClipFrame {
        let image: CIImage
        let subjectBounds: CGRect?
    }

    private func clipFrameImage(
        clipID: String,
        at time: TimeInterval,
        sourceStart: TimeInterval = 0,
        sourceEnd: TimeInterval? = nil
    ) -> RenderedClipFrame? {
        guard let clip = FrameCache.shared.clip(id: clipID) else { return nil }
        let playbackFrames = clip.playbackFrameIndices(reversed: isPlaybackReversed)
        guard !playbackFrames.isEmpty else { return nil }
        let fps = clip.fps
        guard fps.isFinite, fps > 0 else {
            if let frame = FrameCache.shared.cachedFrame(for: clip, index: playbackFrames[0]) {
                return clipFrameImage(frame, clip: clip)
            }
            return nil
        }
        let sourceDuration = clip.playbackSourceDuration
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
                return clipFrameImage(frame, clip: clip)
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
        return clipFrameImage(frame, clip: clip)
    }

    private func clipFrameImage(_ frame: CGImage, clip: SegmentedClip) -> RenderedClipFrame {
        // Keep the complete source canvas for positioning, but carry the visible
        // subject bounds separately so clip effects can size themselves from the
        // same alpha boundary used by option previews.
        var subjectBounds = AlphaSubjectBounds.visiblePixelBounds(in: frame)
        var image = CIImage(cgImage: frame)
        // Thumbnail decoding already applies the crop in FrameCache. Full-resolution
        // frames are cropped here before the stored clockwise rotation is applied.
        if frameMaxPixelSize == nil, clip.cropRect != nil {
            let raw = clip.rawCropRect
            let crop = CGRect(
                x: image.extent.minX + raw.minX * image.extent.width,
                y: image.extent.minY + raw.minY * image.extent.height,
                width: raw.width * image.extent.width,
                height: raw.height * image.extent.height
            ).intersection(image.extent)
            if crop.width > 0, crop.height > 0 {
                subjectBounds = subjectBounds?.intersection(crop)
                image = image.cropped(to: crop)
            }
        }
        let turns = clip.normalizedRotationQuarterTurns
        guard turns != 0 else {
            return RenderedClipFrame(image: image, subjectBounds: subjectBounds)
        }

        let rotation = CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2)
        let rotated = image.transformed(by: rotation)
        let translation = CGAffineTransform(
            translationX: -rotated.extent.minX,
            y: -rotated.extent.minY
        )
        let normalizedBounds = subjectBounds?
            .applying(rotation)
            .applying(translation)
        return RenderedClipFrame(
            image: rotated.transformed(by: translation),
            subjectBounds: normalizedBounds
        )
    }

    /// 素材详情页的旋转属于素材本身，因此在进入元素变换和描边处理前统一应用。
    /// Core Image 的 y-up 坐标中，正 90° 对应界面里的顺时针旋转。
    private func rotatedClipImage(_ image: CIImage, quarterTurns: Int) -> CIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2))
        return rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX,
            y: -rotated.extent.minY
        ))
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
        case .outline:
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

    /// Single source of truth for candidate style samples and normal clip rendering.
    private func applyClipStyle(
        _ style: StickerStyle,
        clip: SegmentedClip,
        fixScale: CGFloat,
        subjectBounds: CGRect? = nil,
        to frame: CIImage
    ) -> CIImage {
        if style == .customOutline {
            // 自定义描边：线型×粗细×颜色参数直接渲染，不叠加旧边缘层。
            return outlined(
                frame,
                radius: clip.edgeThickness.radius / max(fixScale, 0.001),
                color: CIColor(hex: clip.edgeColorHex),
                lineStyle: clip.edgeLineStyle,
                fixScale: fixScale,
                clipID: clip.id
            )
        }

        return applyStickerStyle(
            style,
            thickness: clip.edgeThickness,
            fixScale: fixScale,
            subjectBounds: subjectBounds,
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

    private func applyStickerStyle(
        _ style: StickerStyle,
        thickness: EdgeThickness,
        fixScale: CGFloat,
        subjectBounds: CGRect? = nil,
        to image: CIImage
    ) -> CIImage {
        // 预览和实际渲染都基于可见主体，而不是包含透明边距的完整素材画布。
        // 这样主体很小或透明边距很大的抠图不会得到视觉上过粗的描边。
        let base = AlphaSubjectBounds.subjectBase(in: image.extent, bounds: subjectBounds)
        let renderScale = max(fixScale, 0.001)
        switch style {
        case .none:
            return image
        case .outline:
            // 描边贴纸：白色描边（宽度≈短边 3%），边缘柔和渐变
            // `base` 在当前 CIImage 坐标系中，先换算到素材实际像素，再
            // 换回当前渲染坐标；这样预览缩略图与全分辨率输出保持同一比例。
            let targetRadius = max(6, min(base * renderScale * 0.03, 24))
            let radius = max(1, targetRadius / renderScale)
            let layer = outlineLayer(image, radius: radius, color: CIColor(hex: "FFFFFF"), lineStyle: .solid)
            let soft = layer
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, radius * 0.25)])
                .cropped(to: image.extent)
            return image.composited(over: soft)
        case .comic:
            // 漫画贴纸：黑色外描边 + 白色内描边。
            // 现在跟自定义描边共用三档粗细，且按预览缩略图比例换算，
            // 这样用户在两种风格之间切换时，粗细控制不会失效。
            let scale = max(fixScale, 0.001)
            // 白色留白带加倍，同时保留原来的黑色外轮廓宽度：
            // 旧值为白色 0.5R + 黑色 0.5R；现在为白色 R + 黑色 0.5R。
            let blackBand = max(1, thickness.radius * 0.5 / scale)
            let whiteRadius = max(1, thickness.radius / scale)
            let blackRadius = whiteRadius + blackBand
            let black = outlineLayer(image, radius: blackRadius, color: CIColor(hex: "000000"), lineStyle: .solid)
            let white = outlineLayer(image, radius: whiteRadius, color: CIColor(hex: "FFFFFF"), lineStyle: .solid)
            return image.composited(over: white.composited(over: black))
        case .smooth:
            // 平滑贴纸：仅羽化边缘（边缘带变半透明过渡，内部保持清晰不模糊）。
            // 用模糊后的 alpha 作掩码：内部 alpha≈1 → 原图；边缘 0<alpha<1 → 半透明；外部 → 透明
            let targetRadius = min(base * renderScale * 0.012, 6)
            let radius = max(1, targetRadius / renderScale)
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
        let expanded = morphologyExpanded(image, radius: radius)
        return tinted(expanded, color: color)
    }

    /// Core Image 对单次 morphology radius 在部分系统上有上限。
    /// 分段膨胀可以保持大号描边的完整宽度，避免“粗”档被系统截断。
    private func morphologyExpanded(_ image: CIImage, radius: CGFloat) -> CIImage {
        var remaining = max(radius, 0)
        var result = image
        while remaining > 0 {
            let step = min(remaining, 100)
            result = result.applyingFilter(
                "CIMorphologyMaximum",
                parameters: [kCIInputRadiusKey: step]
            )
            remaining -= step
        }
        return result
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
