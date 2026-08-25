import CoreGraphics
import CoreImage
import Foundation

/// Core Image implementation of the reusable paper treatment.
///
/// The expensive part is intentionally rasterized once.  The result is a CGImage
/// so preview and export can share the exact same pixels without putting filters
/// on the animation frame path.
enum NativePaperEffectRenderer {
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true
    ])

    static func clearCaches() {
        context.clearCaches()
    }

    static func canvasOverlay(
        size: CGSize,
        profile: TornEdgeProfile,
        inset: CGFloat,
        effectWidth: CanvasEdgeWidth = .standard
    ) -> CGImage? {
        canvasPaperImage(
            size: size,
            profile: profile,
            inset: inset,
            effectWidth: effectWidth,
            includesOpeningEdge: true
        )
    }

    /// Scalable paper body used beneath authored frame artwork. It expands the
    /// actual paper surface on all four sides but deliberately omits another
    /// contact edge, avoiding a doubled dark outline when the authored frame is
    /// composited above it.
    static func canvasBacking(
        size: CGSize,
        profile: TornEdgeProfile,
        inset: CGFloat
    ) -> CGImage? {
        canvasPaperImage(
            size: size,
            profile: profile,
            inset: inset,
            effectWidth: .standard,
            includesOpeningEdge: false
        )
    }

    private static func canvasPaperImage(
        size: CGSize,
        profile: TornEdgeProfile,
        inset: CGFloat,
        effectWidth: CanvasEdgeWidth,
        includesOpeningEdge: Bool
    ) -> CGImage? {
        let rect = CGRect(origin: .zero, size: size)
        let openingRect = rect.insetBy(dx: inset, dy: inset)
        guard openingRect.width > 2, openingRect.height > 2,
              let openingPath = tornOpeningPath(openingRect, profile: profile),
              let openingMask = displacedMask(
                  size: size,
                  path: openingPath,
                  profile: profile,
                  displacement: displacementAmount(for: profile, inset: inset)
              ) else { return nil }

        let paperMask = invertMask(openingMask, extent: rect)
        let paperColor = CIImage(color: CIColor(red: 0.992, green: 0.985, blue: 0.965, alpha: 1))
            .cropped(to: rect)
        let texture = textureImage(size: size)
        let transparent = transparentImage(croppedTo: rect)
        var result = blend(paperColor, over: transparent, mask: paperMask)
        if let texture {
            result = sourceOver(blend(texture, over: transparent, mask: paperMask), over: result)
        }

        // The contact edge is generated from the same displaced mask as the tear,
        // so the shadow cannot drift away from the actual opening.
        if includesOpeningEdge {
            let edge = edgeImage(
                mask: openingMask,
                extent: rect,
                inset: inset,
                profile: profile,
                effectWidth: effectWidth
            )
            if let edge { result = sourceOver(edge, over: result) }
        }

        // The torn paper is filtered in Core Image. The static corner is added
        // by the caller as a native Core Graphics layer so it can be clipped to
        // the exact corner without CIPageCurl treating the transparent photo
        // opening as a second page.
        return render(result, extent: rect)
    }

    static func tornEdgeOverlay(
        size: CGSize,
        path: CGPath,
        profile: TornEdgeProfile,
        width: CanvasEdgeWidth = .standard
    ) -> CGImage? {
        let rect = CGRect(origin: .zero, size: size)
        let reference = max(rect.width, rect.height)
        let widthRatio: CGFloat
        switch profile {
        case .soft: widthRatio = 0.0075
        case .fibrous: widthRatio = 0.0095
        case .layered: widthRatio = 0.0110
        }
        let nominalWidth = max(reference * widthRatio * width.effectRenderScale, 2.5)
        guard let mask = displacedMask(
            size: size,
            path: path,
            profile: profile,
            displacement: nominalWidth * (profile == .fibrous ? 1.25 : 0.72)
        ) else { return nil }
        let gradient = morphologyGradient(mask, radius: nominalWidth * 0.82) ?? mask
        let fiberCoreGradient = morphologyGradient(mask, radius: nominalWidth * 0.34) ?? gradient
        let insideContactGradient = morphologyGradient(mask, radius: nominalWidth * 0.14) ?? gradient
        let inside = multiply(insideContactGradient, by: mask) ?? insideContactGradient
        let inverseMask = invertMask(mask, extent: rect)
        let outside = multiply(gradient, by: inverseMask) ?? gradient
        let outsideCore = multiply(fiberCoreGradient, by: inverseMask) ?? fiberCoreGradient
        let contact = colorize(inside, color: CIColor(red: 0.16, green: 0.13, blue: 0.09, alpha: 0.045))
        // Keep the generated paper on the paper/reveal side of the cut. The
        // authored frame remains the visible top layer, avoiding a second
        // smooth white outline over its original fibers.
        let paperAlpha = colorize(outside, color: CIColor(
            red: 1.0,
            green: 0.988,
            blue: 0.955,
            alpha: profile == .soft ? 0.68 : 0.84
        ))
        let paperCore = colorize(outsideCore, color: CIColor(
            red: 1.0,
            green: 0.997,
            blue: 0.985,
            alpha: profile == .soft ? 0.82 : 0.96
        ))
        let underside = colorize(outside, color: CIColor(
            red: 0.48,
            green: 0.43,
            blue: 0.34,
            alpha: profile == .layered ? 0.10 : 0.06
        ))
        // A single global light comes from the upper-left. The paper therefore
        // casts down and right (+x, -y in Core Image coordinates) regardless of
        // which partition owns a divider segment.
        let shiftedShadowMask = outside
                .transformed(by: CGAffineTransform(
                    translationX: nominalWidth * 0.24,
                    y: -nominalWidth * 0.24
                ))
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: nominalWidth * 0.42
                ])
                .cropped(to: rect)
        // The shadow is only allowed to fall into the photo. This removes the
        // dark all-around stroke while preserving the upper-left light source.
        let directionalShadowMask = multiply(shiftedShadowMask, by: mask) ?? shiftedShadowMask
        let shadow = colorize(
            directionalShadowMask,
            color: CIColor(red: 0.10, green: 0.085, blue: 0.065, alpha: 0.27)
        )
        var paper = paperAlpha
        if let texture = textureImage(size: size) {
            let transparent = transparentImage(croppedTo: rect)
            let clippedTexture = blend(texture, over: transparent, mask: outside)
            paper = sourceOver(clippedTexture, over: paper)
        }
        let paperLayers = sourceOver(paperCore, over: sourceOver(paper, over: underside))
        let result = sourceOver(contact, over: sourceOver(paperLayers, over: shadow))
        // The path also contains canvas-perimeter segments needed to close the
        // partition mask. Hide their treatment so only the internal dividers
        // look torn; the canvas-level frame remains the sole outer border.
        // Displacement and the two-sided fiber band can extend farther than the
        // nominal radius. Keep that entire treatment away from the canvas
        // perimeter so partition overlays never draw a second outer frame.
        let perimeterInset = min(nominalWidth * 2.15, min(rect.width, rect.height) * 0.12)
        let visibleResult: CIImage
        if let interiorMask = interiorRectMask(size: size, inset: perimeterInset) {
            let featheredMask = interiorMask
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: max(nominalWidth * 0.28, 1.5)
                ])
                .cropped(to: rect)
            visibleResult = blend(
                result,
                over: transparentImage(croppedTo: rect),
                mask: featheredMask
            )
        } else {
            visibleResult = result
        }
        return render(visibleResult, extent: rect)
    }

    private static func interiorRectMask(size: CGSize, inset: CGFloat) -> CIImage? {
        let rect = CGRect(origin: .zero, size: size)
        let interior = rect.insetBy(dx: inset, dy: inset)
        guard interior.width > 1, interior.height > 1 else { return nil }
        return ProceduralRasterRenderer.makeImage(size: size, transparent: false) { context, _ in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(interior)
        }.map(CIImage.init(cgImage:))
    }

    private static func displacedMask(
        size: CGSize,
        path: CGPath,
        profile: TornEdgeProfile,
        displacement: CGFloat
    ) -> CIImage? {
        let rect = CGRect(origin: .zero, size: size)
        guard let base = ProceduralRasterRenderer.makeImage(size: size, transparent: false, draw: { context, _ in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect)
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
        }) else { return nil }

        let input = CIImage(cgImage: base)
        guard let noise = displacementImage(size: size, profile: profile),
              let filter = CIFilter(name: "CIDisplacementDistortion") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(noise, forKey: "inputDisplacementImage")
        filter.setValue(Float(displacement), forKey: kCIInputScaleKey)
        return filter.outputImage?.cropped(to: rect) ?? input
    }

    private static func displacementImage(size: CGSize, profile: TornEdgeProfile) -> CIImage? {
        let seed: UInt64
        switch profile {
        case .soft: seed = 0xD15E_5EED_0001
        case .fibrous: seed = 0xD15E_5EED_0002
        case .layered: seed = 0xD15E_5EED_0003
        }
        return ProceduralRasterRenderer.makeImage(size: size, transparent: false) { context, rect in
            var random = NativePaperRandomNumberGenerator(state: seed)
            let cell = max(min(rect.width, rect.height) * (profile == .fibrous ? 0.018 : 0.032), 6)
            let columns = max(Int(ceil(rect.width / cell)), 1)
            let rows = max(Int(ceil(rect.height / cell)), 1)
            for row in 0..<rows {
                for column in 0..<columns {
                    // CIDisplacementDistortion interprets 0.5 as the neutral
                    // sample. A wide, deterministic range is what creates the
                    // broken edge rather than a barely visible sinusoid.
                    let value = 0.38 + random.nextUnit() * 0.24
                    context.setFillColor(CGColor(gray: value, alpha: 1))
                    context.fill(CGRect(
                        x: rect.minX + CGFloat(column) * cell,
                        y: rect.minY + CGFloat(row) * cell,
                        width: cell + 1,
                        height: cell + 1
                    ))
                }
            }
        }.map(CIImage.init(cgImage:))
    }

    private static func displacementAmount(for profile: TornEdgeProfile, inset: CGFloat) -> CGFloat {
        switch profile {
        case .soft: return min(max(inset * 0.20, 5), 18)
        case .fibrous: return min(max(inset * 0.42, 8), 30)
        case .layered: return min(max(inset * 0.34, 7), 26)
        }
    }

    private static func textureImage(size: CGSize) -> CIImage? {
        ProceduralRasterRenderer.makeImage(size: size, transparent: true) { context, rect in
            PaperTextureRenderer.drawGrain(in: context, bounds: rect, style: .canvas)
        }.map(CIImage.init(cgImage:))
    }

    private static func edgeImage(
        mask: CIImage,
        extent: CGRect,
        inset: CGFloat,
        profile: TornEdgeProfile,
        effectWidth: CanvasEdgeWidth
    ) -> CIImage? {
        let effectScale = effectWidth.effectRenderScale
        let radius = max(inset * (profile == .layered ? 0.090 : 0.065) * effectScale, 3)
        guard let gradient = morphologyGradient(mask, radius: radius) else { return nil }
        let inside = multiply(gradient, by: mask) ?? gradient
        let outside = multiply(gradient, by: invertMask(mask, extent: extent)) ?? gradient
        let contact = colorize(
            inside,
            color: CIColor(red: 0.15, green: 0.12, blue: 0.085, alpha: profile == .layered ? 0.38 : 0.26)
        )
        let contactShadow = contact
            .transformed(by: CGAffineTransform(
                translationX: inset * 0.018 * effectScale,
                y: -inset * 0.022 * effectScale
            ))
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(inset * 0.065 * effectScale, 1.5)
            ])
        let underside = colorize(
            outside,
            color: CIColor(red: 0.46, green: 0.42, blue: 0.35, alpha: profile == .layered ? 0.12 : 0.08)
        )
        let fiberHighlight = colorize(
            outside,
            color: CIColor(red: 1.0, green: 0.985, blue: 0.93, alpha: profile == .layered ? 0.88 : 0.70)
        )
        return sourceOver(
            fiberHighlight,
            over: sourceOver(underside, over: sourceOver(contactShadow, over: contact))
        ).cropped(to: extent)
    }

    private static func tornOpeningPath(_ rect: CGRect, profile: TornEdgeProfile) -> CGPath? {
        let path = CGMutablePath()
        TornEdgeGeometry.addRect(rect, profile: profile, in: path)
        return path
    }

    private static func invertMask(_ image: CIImage, extent: CGRect) -> CIImage {
        image.applyingFilter("CIColorInvert").cropped(to: extent)
    }

    private static func morphologyGradient(_ image: CIImage, radius: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CIMorphologyGradient") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(Float(radius), forKey: kCIInputRadiusKey)
        return filter.outputImage
    }

    private static func multiply(_ image: CIImage, by mask: CIImage) -> CIImage? {
        guard let filter = CIFilter(name: "CIMultiplyCompositing") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(mask, forKey: kCIInputBackgroundImageKey)
        return filter.outputImage
    }

    private static func colorize(_ image: CIImage, color: CIColor) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: color.red, y: color.green, z: color.blue, w: 0)
        ])
    }

    private static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ])
    }

    private static func sourceOver(_ foreground: CIImage, over background: CIImage) -> CIImage {
        foreground.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: background
        ])
    }

    private static func render(_ image: CIImage, extent: CGRect) -> CGImage? {
        context.createCGImage(image, from: extent)
    }

    private static func transparentImage(croppedTo rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
    }
}

private struct NativePaperRandomNumberGenerator {
    var state: UInt64

    mutating func nextUnit() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat((state >> 40) & 0x00FF_FFFF) / CGFloat(0x00FF_FFFF)
    }
}
