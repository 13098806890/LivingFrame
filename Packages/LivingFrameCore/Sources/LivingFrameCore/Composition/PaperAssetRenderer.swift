import CoreGraphics
import Foundation
import ImageIO

/// Renders the three paper styles extracted from the authored A/B/C reference.
/// Once assembled, the result is cached by PaperEffectRenderer.
enum PaperAssetRenderer {
    static func borderOverlay(
        size: CGSize,
        profile: TornEdgeProfile,
        borderInset: CGFloat,
        foldedCorner _: PaperFoldCorner?
    ) -> CGImage? {
        guard let authoredFrame = image(named: "paper-mockup-\(profile.rawValue)-frame") else { return nil }
        return authoredBorderOverlay(
            frame: authoredFrame,
            size: size,
            profile: profile,
            borderInset: borderInset
        )
    }

    /// The reference artwork is stored as a complete frame so its asymmetric
    /// corners, fiber texture and cast shadow stay together. Only the four
    /// straight edge spans are stretched; corners are scaled uniformly.
    private static func authoredBorderOverlay(
        frame: CGImage,
        size: CGSize,
        profile: TornEdgeProfile,
        borderInset: CGFloat
    ) -> CGImage? {
        let sourceSize = CGSize(width: frame.width, height: frame.height)
        let sourceOpening = sourceOpeningRect(for: profile, in: sourceSize)
        let destination = CGRect(origin: .zero, size: size)
        let inset = max(borderInset, 1)

        return ProceduralRasterRenderer.makeImage(size: size) { context, _ in
            context.interpolationQuality = .high
            if profile == .layered {
                // C's curl, sheet underneath and long shadow cross both the
                // right and bottom slice boundaries. Keep that artwork as one
                // continuous layer so no rectangular seam can appear.
                context.draw(frame, in: destination)
            } else {
                drawNineSlice(
                    frame,
                    sourceSize: sourceSize,
                    opening: sourceOpening,
                    destination: destination,
                    inset: min(inset, min(destination.width, destination.height) * 0.34),
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
        inset: CGFloat,
        in context: CGContext
    ) {
        let sourceX = [CGFloat(0), opening.minX, opening.maxX, sourceSize.width]
        let sourceY = [CGFloat(0), opening.minY, opening.maxY, sourceSize.height]
        let destinationX = [CGFloat(0), inset, destination.width - inset, destination.width]
        // Destination rows are still expressed top-to-bottom; convert each
        // row to the bitmap context's bottom-left origin when placing it.
        let destinationY = [CGFloat(0), inset, destination.height - inset, destination.height]

        for row in 0..<3 {
            for column in 0..<3 where !(row == 1 && column == 1) {
                let source = CGRect(
                    x: sourceX[column],
                    y: sourceY[row],
                    width: sourceX[column + 1] - sourceX[column],
                    height: sourceY[row + 1] - sourceY[row]
                )
                let bottom = destination.height - destinationY[row + 1]
                let target = CGRect(
                    x: destinationX[column],
                    y: bottom,
                    width: destinationX[column + 1] - destinationX[column],
                    height: destinationY[row + 1] - destinationY[row]
                )
                drawSlice(image, source: source, destination: target, in: context)
            }
        }
    }

    /// Coordinates are measured from the top-left of the authored PNGs.
    private static func sourceOpeningRect(for profile: TornEdgeProfile, in size: CGSize) -> CGRect {
        switch profile {
        case .soft:
            CGRect(x: 40, y: 45, width: size.width - 70, height: size.height - 93)
        case .fibrous:
            CGRect(x: 54, y: 59, width: size.width - 117, height: size.height - 119)
        case .layered:
            CGRect(x: 45, y: 41, width: size.width - 121, height: size.height - 109)
        }
    }

    private static func drawSlice(
        _ image: CGImage,
        source topLeftSource: CGRect,
        destination: CGRect,
        in context: CGContext
    ) {
        guard topLeftSource.width > 0,
              topLeftSource.height > 0,
              destination.width > 0,
              destination.height > 0 else { return }

        // ImageIO preserves the PNG's top-left pixel coordinates for CGImage
        // cropping. Destination placement is converted separately above.
        guard let slice = image.cropping(to: topLeftSource.integral) else { return }
        context.draw(slice, in: destination)
    }

    private static func image(named name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
