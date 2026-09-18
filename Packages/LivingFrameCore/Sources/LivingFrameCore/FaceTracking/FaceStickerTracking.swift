import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Landmark positions inside a sticker image. Points use normalized top-left
/// coordinates so the values can be authored alongside the PNG asset.
public struct StickerFaceAnchors: Codable, Equatable, Sendable {
    public var leftEye: CGPoint
    public var rightEye: CGPoint

    public init(leftEye: CGPoint, rightEye: CGPoint) {
        self.leftEye = leftEye
        self.rightEye = rightEye
    }
}

/// Detects eye centers in every source frame of a clip. Analysis runs locally
/// with Vision; missed frames are interpolated and lightly smoothed for stable playback.
public struct FaceStickerTracker: Sendable {
    public enum TrackingError: Error {
        case noUsableFrames
        case noFaceDetected
    }

    private struct FrameInput: Sendable {
        let index: Int
        let url: URL
    }

    public init() {}

    public func analyze(clip: SegmentedClip, maxPixelSize: Int = 512) async throws -> [FaceStickerKeyframe] {
        let frameIndices = Array(Set(clip.playbackFrameIndices(reversed: false))).sorted()
        guard !frameIndices.isEmpty else { throw TrackingError.noUsableFrames }
        let inputs = frameIndices.map { FrameInput(index: $0, url: clip.frameURL(index: $0)) }
        let cropRect = clip.rawCropRect
        let rotationQuarterTurns = clip.normalizedRotationQuarterTurns
        let boundedPixelSize = min(max(maxPixelSize, 128), 1024)

        return try await Task.detached(priority: .userInitiated) {
            try Self.analyze(
                inputs: inputs,
                cropRect: cropRect,
                rotationQuarterTurns: rotationQuarterTurns,
                maxPixelSize: boundedPixelSize
            )
        }.value
    }

    private static func analyze(
        inputs: [FrameInput],
        cropRect: CGRect,
        rotationQuarterTurns: Int,
        maxPixelSize: Int
    ) throws -> [FaceStickerKeyframe] {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var detected: [Int: (CGPoint, CGPoint, CGFloat?)] = [:]

        for input in inputs {
            guard let image = orientedThumbnail(
                at: input.url,
                cropRect: cropRect,
                rotationQuarterTurns: rotationQuarterTurns,
                maxPixelSize: maxPixelSize,
                context: context
            ) else { continue }

            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let faces = request.results,
                  let eyes = eyes(in: faces) else { continue }
            detected[input.index] = eyes
        }

        guard !detected.isEmpty else { throw TrackingError.noFaceDetected }
        let frameIndices = inputs.map(\.index)
        let filled = interpolateMissingFrames(frameIndices: frameIndices, detected: detected)
        return smooth(frameIndices: frameIndices, points: filled)
    }

    private static func orientedThumbnail(
        at url: URL,
        cropRect: CGRect,
        rotationQuarterTurns: Int,
        maxPixelSize: Int,
        context: CIContext
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            return nil
        }

        var image = CIImage(cgImage: thumbnail)
        let normalizedCrop = CGRect(
            x: image.extent.minX + cropRect.minX * image.extent.width,
            y: image.extent.minY + cropRect.minY * image.extent.height,
            width: cropRect.width * image.extent.width,
            height: cropRect.height * image.extent.height
        ).intersection(image.extent)
        if normalizedCrop.width > 0, normalizedCrop.height > 0 {
            image = image.cropped(to: normalizedCrop)
        }

        let turns = ((rotationQuarterTurns % 4) + 4) % 4
        if turns != 0 {
            let rotated = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2))
            image = rotated.transformed(by: CGAffineTransform(
                translationX: -rotated.extent.minX,
                y: -rotated.extent.minY
            ))
        }
        return context.createCGImage(image, from: image.extent.integral)
    }

    private static func eyes(in faces: [VNFaceObservation]) -> (CGPoint, CGPoint, CGFloat?)? {
        for face in faces.sorted(by: { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }) {
            let yaw = face.yaw.map { CGFloat($0.doubleValue) }
            let left = face.landmarks.flatMap { center(of: $0.leftEye, faceBounds: face.boundingBox) }
            let right = face.landmarks.flatMap { center(of: $0.rightEye, faceBounds: face.boundingBox) }

            if let left, let right {
                // Use image-left/image-right order. It gives a stable asset orientation
                // for front-facing images even when Vision's anatomical labels swap.
                let ordered = left.x <= right.x ? (left, right) : (right, left)
                guard hypot(ordered.1.x - ordered.0.x, ordered.1.y - ordered.0.y) > 0.012 else {
                    continue
                }
                return (ordered.0, ordered.1, yaw)
            }

            // A profile face often exposes only one eye landmark. Keep that eye as
            // the pair midpoint and estimate the hidden eye gap from face width and
            // yaw; this also lets the renderer choose its narrow side-view anchors.
            if let visibleEye = left ?? right,
               face.boundingBox.width > 0.02 {
                let angle = min(abs(yaw ?? 0), .pi / 2)
                let gapInFace = face.boundingBox.width * (0.42 * cos(angle) + 0.08)
                let halfGap = max(gapInFace, face.boundingBox.width * 0.08) / 2
                return (
                    CGPoint(x: visibleEye.x - halfGap, y: visibleEye.y),
                    CGPoint(x: visibleEye.x + halfGap, y: visibleEye.y),
                    yaw
                )
            }

            // If Vision finds the face and yaw but no eye regions, use a conservative
            // eye-line estimate so a full-profile clip can still carry the sticker.
            if let yaw, face.boundingBox.width > 0.02, face.boundingBox.height > 0.02 {
                let angle = min(abs(yaw), .pi / 2)
                let gap = max(face.boundingBox.width * (0.42 * cos(angle) + 0.08), face.boundingBox.width * 0.08)
                let centerX = face.boundingBox.midX
                let eyeY = face.boundingBox.minY + face.boundingBox.height * 0.68
                return (
                    CGPoint(x: centerX - gap / 2, y: eyeY),
                    CGPoint(x: centerX + gap / 2, y: eyeY),
                    yaw
                )
            }
        }
        return nil
    }

    private static func center(
        of region: VNFaceLandmarkRegion2D?,
        faceBounds: CGRect
    ) -> CGPoint? {
        guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
        let localCenter = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let meanX = localCenter.x / CGFloat(points.count)
        let meanY = localCenter.y / CGFloat(points.count)
        return CGPoint(
            x: faceBounds.minX + meanX * faceBounds.width,
            y: faceBounds.minY + meanY * faceBounds.height
        )
    }

    private static func interpolateMissingFrames(
        frameIndices: [Int],
        detected: [Int: (CGPoint, CGPoint, CGFloat?)]
    ) -> [Int: (CGPoint, CGPoint, CGFloat?)] {
        let knownIndices = detected.keys.sorted()
        var result: [Int: (CGPoint, CGPoint, CGFloat?)] = [:]

        for frameIndex in frameIndices {
            if let known = detected[frameIndex] {
                result[frameIndex] = known
                continue
            }

            let beforeIndex = knownIndices.last(where: { $0 < frameIndex })
            let afterIndex = knownIndices.first(where: { $0 > frameIndex })
            switch (beforeIndex, afterIndex) {
            case let (.some(before), .some(after)):
                guard let a = detected[before], let b = detected[after] else { continue }
                let amount = CGFloat(frameIndex - before) / CGFloat(after - before)
                result[frameIndex] = (
                    interpolate(a.0, b.0, amount),
                    interpolate(a.1, b.1, amount),
                    interpolate(a.2, b.2, amount)
                )
            case let (.some(nearest), .none), let (.none, .some(nearest)):
                result[frameIndex] = detected[nearest]
            case (.none, .none):
                break
            }
        }
        return result
    }

    private static func smooth(
        frameIndices: [Int],
        points: [Int: (CGPoint, CGPoint, CGFloat?)]
    ) -> [FaceStickerKeyframe] {
        frameIndices.enumerated().compactMap { position, frameIndex in
            guard let current = points[frameIndex] else { return nil }
            let previousIndex = frameIndices[max(position - 1, 0)]
            let nextIndex = frameIndices[min(position + 1, frameIndices.count - 1)]
            let previous = points[previousIndex] ?? current
            let next = points[nextIndex] ?? current
            return FaceStickerKeyframe(
                frameIndex: frameIndex,
                leftEye: weightedAverage(previous.0, current.0, next.0),
                rightEye: weightedAverage(previous.1, current.1, next.1),
                yaw: weightedAverage(previous.2, current.2, next.2)
            )
        }
    }

    private static func interpolate(_ a: CGPoint, _ b: CGPoint, _ amount: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
    }

    private static func weightedAverage(_ previous: CGPoint, _ current: CGPoint, _ next: CGPoint) -> CGPoint {
        CGPoint(
            x: previous.x * 0.2 + current.x * 0.6 + next.x * 0.2,
            y: previous.y * 0.2 + current.y * 0.6 + next.y * 0.2
        )
    }

    private static func interpolate(_ first: CGFloat?, _ second: CGFloat?, _ amount: CGFloat) -> CGFloat? {
        switch (first, second) {
        case let (.some(a), .some(b)): a + (b - a) * amount
        case let (.some(value), .none), let (.none, .some(value)): value
        case (.none, .none): nil
        }
    }

    private static func weightedAverage(_ previous: CGFloat?, _ current: CGFloat?, _ next: CGFloat?) -> CGFloat? {
        let values = [(previous, 0.2), (current, 0.6), (next, 0.2)].compactMap { value, weight in
            value.map { ($0, weight) }
        }
        let weight = values.reduce(CGFloat.zero) { $0 + $1.1 }
        guard weight > 0 else { return nil }
        return values.reduce(CGFloat.zero) { $0 + $1.0 * $1.1 } / weight
    }
}

/// Converts source-frame eye centers into the Core Image canvas transform for a
/// sticker whose two authored anchors correspond to the detected eyes.
public enum FaceStickerPlacement {
    /// Smooths scale in log space so proportional size changes feel consistent.
    /// A one-frame outlier is first limited against the median of its neighbors;
    /// sustained approach/retreat remains intact because adjacent frames move too.
    public static func smoothedScale(
        previous: CGFloat,
        current: CGFloat,
        next: CGFloat,
        maximumNeighborRatio: CGFloat = 1.25
    ) -> CGFloat {
        let values = [previous, current, next]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }),
              maximumNeighborRatio.isFinite, maximumNeighborRatio > 1 else {
            return current
        }

        let logarithms = values.map { log($0) }
        let median = logarithms.sorted()[1]
        let maximumDeviation = log(maximumNeighborRatio)
        let bounded = logarithms.map {
            min(max($0, median - maximumDeviation), median + maximumDeviation)
        }
        return exp(bounded[0] * 0.2 + bounded[1] * 0.6 + bounded[2] * 0.2)
    }

    public static func transform(
        for keyframe: FaceStickerKeyframe,
        frameSize: CGSize,
        clipTransform: ElementTransform,
        stickerSize: CGSize,
        stickerAnchors: StickerFaceAnchors,
        userOffset: ElementTransform = ElementTransform(position: .zero),
        scaleOverride: CGFloat? = nil
    ) -> ElementTransform? {
        guard frameSize.width > 0, frameSize.height > 0,
              stickerSize.width > 0, stickerSize.height > 0,
              clipTransform.scale.isFinite, clipTransform.scale > 0,
              userOffset.scale.isFinite, userOffset.scale > 0 else {
            return nil
        }

        let leftEye = CGPoint(x: keyframe.leftEye.x * frameSize.width, y: keyframe.leftEye.y * frameSize.height)
        let rightEye = CGPoint(x: keyframe.rightEye.x * frameSize.width, y: keyframe.rightEye.y * frameSize.height)
        let eyeVector = CGPoint(x: rightEye.x - leftEye.x, y: rightEye.y - leftEye.y)
        let eyeDistance = hypot(eyeVector.x, eyeVector.y) * clipTransform.scale
        let eyeAngle = atan2(eyeVector.y, eyeVector.x) + clipTransform.rotation

        let leftAnchor = CGPoint(
            x: stickerAnchors.leftEye.x * stickerSize.width,
            y: (1 - stickerAnchors.leftEye.y) * stickerSize.height
        )
        let rightAnchor = CGPoint(
            x: stickerAnchors.rightEye.x * stickerSize.width,
            y: (1 - stickerAnchors.rightEye.y) * stickerSize.height
        )
        let anchorVector = CGPoint(x: rightAnchor.x - leftAnchor.x, y: rightAnchor.y - leftAnchor.y)
        let anchorDistance = hypot(anchorVector.x, anchorVector.y)
        guard eyeDistance.isFinite, eyeDistance > 0,
              anchorDistance.isFinite, anchorDistance > 0 else {
            return nil
        }

        let calculatedScale = eyeDistance / anchorDistance * userOffset.scale
        let scale = scaleOverride.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? calculatedScale
        let rotation = eyeAngle - atan2(anchorVector.y, anchorVector.x) + userOffset.rotation
        let eyeMidpoint = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
        let clipOffset = CGPoint(
            x: (eyeMidpoint.x - frameSize.width / 2) * clipTransform.scale,
            y: (eyeMidpoint.y - frameSize.height / 2) * clipTransform.scale
        )
        let clipCos = cos(clipTransform.rotation)
        let clipSin = sin(clipTransform.rotation)
        let canvasEyeMidpoint = CGPoint(
            x: clipTransform.position.x + clipOffset.x * clipCos - clipOffset.y * clipSin,
            y: clipTransform.position.y + clipOffset.x * clipSin + clipOffset.y * clipCos
        )

        let anchorMidpoint = CGPoint(x: (leftAnchor.x + rightAnchor.x) / 2, y: (leftAnchor.y + rightAnchor.y) / 2)
        let stickerOffset = CGPoint(
            x: (anchorMidpoint.x - stickerSize.width / 2) * scale,
            y: (anchorMidpoint.y - stickerSize.height / 2) * scale
        )
        let stickerCos = cos(rotation)
        let stickerSin = sin(rotation)
        let rotatedStickerOffset = CGPoint(
            x: stickerOffset.x * stickerCos - stickerOffset.y * stickerSin,
            y: stickerOffset.x * stickerSin + stickerOffset.y * stickerCos
        )

        return ElementTransform(
            position: CGPoint(
                x: canvasEyeMidpoint.x - rotatedStickerOffset.x + userOffset.position.x,
                y: canvasEyeMidpoint.y - rotatedStickerOffset.y + userOffset.position.y
            ),
            scale: scale,
            rotation: rotation
        )
    }
}
