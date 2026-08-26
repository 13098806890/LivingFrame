import CoreGraphics
import Foundation
import ImageIO

/// Renders the two authored transparent paper overlays.
/// Once assembled, the result is cached by PaperEffectRenderer.
enum PaperAssetRenderer {
    static func destinationOpeningRect(
        size: CGSize,
        profile: TornEdgeProfile,
        borderInset: CGFloat
    ) -> CGRect {
        let destination = CGRect(origin: .zero, size: size)
        guard let frame = image(named: assetName(for: profile)) else {
            let inset = min(max(borderInset, 1), min(size.width, size.height) * 0.34)
            return destination.insetBy(dx: inset, dy: inset)
        }

        // Keep the authored frame's edge thickness uniform. The center opening
        // may expand to the requested canvas, but the paper itself is never
        // stretched independently on X and Y.
        let sourceBounds = sourceFrameRect(
            for: profile,
            in: CGSize(width: frame.width, height: frame.height)
        )
        let sourceSize = sourceBounds.size
        let opening = sourceOpeningRect(for: profile, in: sourceSize)
        // The tactile asset contains an irregular bottom-right curl. Its
        // opaque paper crosses into the nominal rectangular opening, so the
        // opening must be mapped from the complete authored image rather than
        // inferred from independent edge slices.
        if profile == .layered {
            return CGRect(
                x: opening.minX / sourceSize.width * size.width,
                y: (sourceSize.height - opening.maxY) / sourceSize.height * size.height,
                width: opening.width / sourceSize.width * size.width,
                height: opening.height / sourceSize.height * size.height
            )
        }
        let scale = min(
            size.width / sourceSize.width,
            size.height / sourceSize.height
        )
        let left = opening.minX * scale
        let right = (sourceSize.width - opening.maxX) * scale
        let top = opening.minY * scale
        let bottom = (sourceSize.height - opening.maxY) * scale
        return CGRect(
            x: left,
            y: bottom,
            width: max(size.width - left - right, 1),
            height: max(size.height - top - bottom, 1)
        )
    }

    static func borderOverlay(
        size: CGSize,
        profile: TornEdgeProfile,
        borderInset: CGFloat,
        foldedCorner _: PaperFoldCorner?
    ) -> CGImage? {
        guard let authoredFrame = image(named: assetName(for: profile)) else { return nil }
        return authoredBorderOverlay(
            frame: authoredFrame,
            size: size,
            profile: profile,
            borderInset: borderInset
        )
    }

    /// Renders only an authored paper edge along internal partition dividers.
    /// This deliberately does not use the complete canvas frame, so it cannot
    /// introduce a second outer border or duplicate a curled corner.
    static func internalDividerOverlay(
        size: CGSize,
        profile: TornEdgeProfile,
        segments: [(CGPoint, CGPoint)],
        effectWidth: CanvasEdgeWidth
    ) -> CGImage? {
        guard !segments.isEmpty,
              let authoredFrame = image(named: assetName(for: profile)) else { return nil }

        let sourceBounds = sourceFrameRect(
            for: profile,
            in: CGSize(width: authoredFrame.width, height: authoredFrame.height)
        )
        guard let croppedFrame = authoredFrame.cropping(to: sourceBounds.integral) else { return nil }
        let sourceSize = sourceBounds.size
        let sourceOpening = sourceOpeningRect(for: profile, in: sourceSize)
        let sourceStrip = CGRect(
            x: 0,
            y: 0,
            width: sourceSize.width,
            height: max(sourceOpening.minY, 1)
        ).integral
        guard let strip = croppedFrame.cropping(to: sourceStrip) else { return nil }

        let shortSide = min(size.width, size.height)
        let thickness = min(
            max(shortSide * 0.030 * effectWidth.effectRenderScale, 10),
            30
        )

        return ProceduralRasterRenderer.makeImage(size: size) { context, _ in
            context.interpolationQuality = .high
            for (start, end) in segments {
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = hypot(dx, dy)
                guard length > 2 else { continue }

                let midpoint = CGPoint(
                    x: (start.x + end.x) * 0.5,
                    y: (start.y + end.y) * 0.5
                )
                let angle = atan2(dy, dx)
                context.saveGState()
                context.translateBy(x: midpoint.x, y: midpoint.y)
                context.rotate(by: angle)
                context.draw(
                    strip,
                    in: CGRect(
                        x: -length * 0.5,
                        y: -thickness * 0.5,
                        width: length,
                        height: thickness
                    )
                )
                context.restoreGState()
            }
        }
    }

    /// The transparent artwork is stored as a complete frame so its paper
    /// texture, cast shadow and (for the tactile style) curled corner stay
    /// together. Establish the edge thickness with a uniform scale, then
    /// expand only the photo opening to fit the actual canvas.
    private static func authoredBorderOverlay(
        frame: CGImage,
        size: CGSize,
        profile: TornEdgeProfile,
        borderInset: CGFloat
    ) -> CGImage? {
        let sourceBounds = sourceFrameRect(
            for: profile,
            in: CGSize(width: frame.width, height: frame.height)
        )
        guard let croppedFrame = frame.cropping(to: sourceBounds.integral) else { return nil }
        let sourceSize = sourceBounds.size
        let sourceOpening = sourceOpeningRect(for: profile, in: sourceSize)
        let destination = CGRect(origin: .zero, size: size)
        let destinationOpening = destinationOpeningRect(
            size: size,
            profile: profile,
            borderInset: borderInset
        )

        return ProceduralRasterRenderer.makeImage(size: size) { context, _ in
            context.interpolationQuality = .high
            if profile == .layered {
                // Keep the authored curl in the same image as the frame. A
                // nine-slice would discard the irregular portion that crosses
                // into the rectangular photo opening.
                context.draw(croppedFrame, in: destination)
            } else {
                drawNineSlice(
                    croppedFrame,
                    sourceSize: sourceSize,
                    opening: sourceOpening,
                    destination: destination,
                    destinationOpening: destinationOpening,
                    in: context
                )
            }
        }
    }

    private static func drawNineSlice(
        _ image: CGImage,
        sourceSize: CGSize,
        opening: CGRect,
        destination: CGRect,
        destinationOpening: CGRect,
        in context: CGContext
    ) {
        let sourceX = [CGFloat(0), opening.minX, opening.maxX, sourceSize.width]
        let sourceY = [CGFloat(0), opening.minY, opening.maxY, sourceSize.height]
        let destinationX = [
            CGFloat(0), destinationOpening.minX,
            destinationOpening.maxX, destination.width
        ]
        let destinationY = [
            CGFloat(0), destination.height - destinationOpening.maxY,
            destination.height - destinationOpening.minY, destination.height
        ]
        // CG 的高质量插值会从相邻切片的透明边缘取样，在四个角留下
        // 1px 左右的接缝。让相邻纸片在目标空间轻微重叠，覆盖这些采样缝隙；
        // 重叠量远小于纸边宽度，不会改变相纸开口的位置。
        let overlap = min(1.25, max(0.5, min(destination.width, destination.height) * 0.0015))

        for row in 0..<3 {
            for column in 0..<3 where !(row == 1 && column == 1) {
                let source = CGRect(
                    x: sourceX[column],
                    y: sourceY[row],
                    width: sourceX[column + 1] - sourceX[column],
                    height: sourceY[row + 1] - sourceY[row]
                )
                var target = CGRect(
                    x: destinationX[column],
                    y: destination.height - destinationY[row + 1],
                    width: destinationX[column + 1] - destinationX[column],
                    height: destinationY[row + 1] - destinationY[row]
                )
                if column > 0 {
                    target.origin.x -= overlap
                    target.size.width += overlap
                }
                if column < 2 {
                    target.size.width += overlap
                }
                if row > 0 {
                    target.origin.y -= overlap
                    target.size.height += overlap
                }
                if row < 2 {
                    target.size.height += overlap
                }
                target = target.intersection(destination)
                guard let slice = image.cropping(to: source.integral) else { continue }
                context.draw(slice, in: target)
            }
        }
    }

    /// Coordinates are measured from the top-left of the authored PNGs.
    private static func sourceOpeningRect(for profile: TornEdgeProfile, in size: CGSize) -> CGRect {
        switch profile {
        case .soft:
            // bb.png opening, measured from the cropped frame's top-left.
            CGRect(x: 75, y: 86, width: 1040, height: 830)
        case .fibrous:
            // b.png opening, measured from the cropped frame's top-left.
            CGRect(x: 78, y: 94, width: 1053, height: 832)
        case .layered:
            // Same rectangular envelope; b.png's alpha removes the
            // irregular curled-corner area from its lower-right edge.
            CGRect(x: 78, y: 94, width: 1053, height: 832)
        }
    }

    /// The generated PNGs contain transparent padding around the authored
    /// artwork. Remove that padding before fitting the frame to the canvas;
    /// otherwise the paper appears as a small card floating inside it.
    private static func sourceFrameRect(for profile: TornEdgeProfile, in _: CGSize) -> CGRect {
        switch profile {
        case .soft:
            // User-supplied bb.png alpha bounds: (175, 11) ... (1363, 1015)
            CGRect(x: 175, y: 11, width: 1188, height: 1004)
        case .fibrous, .layered:
            // User-supplied b.png alpha bounds including the curled corner:
            // (161, 0) ... (1374, 1011)
            CGRect(x: 161, y: 0, width: 1213, height: 1011)
        }
    }

    private static func assetName(for profile: TornEdgeProfile) -> String {
        switch profile {
        case .soft:
            "paper-transparent-soft-frame"
        case .fibrous, .layered:
            "paper-transparent-tactile-frame"
        }
    }

    private static func image(named name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
