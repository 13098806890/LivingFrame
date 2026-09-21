import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Errors raised while loading or executing the bundled SAM 2 Core ML models.
public enum SAM2Error: Error, LocalizedError {
    case modelNotFound(String)
    case invalidImage
    case invalidModelOutput

    public var errorDescription: String? {
        switch self {
        case let .modelNotFound(name):
            return "SAM2 model not found: \(name)"
        case .invalidImage:
            return "SAM2 received an empty image"
        case .invalidModelOutput:
            return "SAM2 returned an unsupported model output"
        }
    }
}

/// Lightweight SAM 2.1 Tiny image-prompt segmenter.
///
/// Apple ships this conversion as three Core ML packages: image encoder,
/// prompt encoder and mask decoder. The image path is intentionally kept
/// separate from the UI/Video pipeline: encode each processed frame with a
/// point prompt, then move that prompt to the decoded mask's center so a
/// moving target can be followed without collapsing it into a nearby person.
public final class SAM2Segmenter: @unchecked Sendable {
    private struct ImageFeatures {
        let imageEmbedding: MLMultiArray
        let featureS0: MLMultiArray
        let featureS1: MLMultiArray
    }

    private static let cacheLock = NSLock()
    private static var cachedSegmenter: SAM2Segmenter?

    private let encoder: MLModel
    private let promptEncoder: MLModel
    private let decoder: MLModel
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private static let inputSize = 1024

    /// Load the three model packages from the Swift Package resource bundle.
    public static func bundled() throws -> SAM2Segmenter {
        func resourceURL(_ name: String) throws -> URL {
            guard let url = Bundle.module.url(
                forResource: name,
                // SwiftPM resource bundles are code-signed recursively. A
                // directory with a package/model extension is treated as a
                // nested bundle by codesign, so the checked-in resource has
                // no extension while retaining the official package contents.
                withExtension: nil,
                subdirectory: "SAM2Models/SAM2"
            ) else {
                throw SAM2Error.modelNotFound(name)
            }
            return url
        }

        return try SAM2Segmenter(
            encoderURL: resourceURL("SAM2_1TinyImageEncoderFLOAT16"),
            promptEncoderURL: resourceURL("SAM2_1TinyPromptEncoderFLOAT16"),
            decoderURL: resourceURL("SAM2_1TinyMaskDecoderFLOAT16")
        )
    }

    /// Reuse the compiled Core ML models across prompt-preview taps. Loading
    /// the three model packages for every tap makes the picker look stuck and
    /// can leave several expensive preview inferences running at once.
    public static func cached() throws -> SAM2Segmenter {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedSegmenter {
            return cachedSegmenter
        }
        let segmenter = try bundled()
        cachedSegmenter = segmenter
        return segmenter
    }

    /// Loads the three `.mlpackage`/`.mlmodelc` components.
    public init(encoderURL: URL, promptEncoderURL: URL, decoderURL: URL) throws {
        func load(_ url: URL) throws -> MLModel {
            let compiled = url.pathExtension == "mlmodelc"
                ? url
                : try MLModel.compileModel(at: url)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }

        encoder = try load(encoderURL)
        promptEncoder = try load(promptEncoderURL)
        decoder = try load(decoderURL)
    }

    /// Segment the object under a normalized top-left-origin point.
    public func mask(
        for image: CIImage,
        at point: CGPoint
    ) -> CIImage? {
        maskWithScore(for: image, at: point)?.mask
    }

    /// Segment a target using the structured first-frame prompt.
    ///
    /// The checked-in Apple export currently accepts one point per inference.
    /// We keep the main foreground point as the positive prompt, then subtract
    /// masks prompted by background points. This gives the user a real
    /// correction path today while preserving an API that can later consume a
    /// multi-point/box Prompt Encoder export directly.
    public func mask(
        for image: CIImage,
        prompt: SAM2Prompt
    ) -> CIImage? {
        maskWithScore(for: image, prompt: prompt)?.mask
    }

    /// Same as `mask(for:prompt:)`, with the primary foreground confidence.
    public func maskWithScore(
        for image: CIImage,
        prompt: SAM2Prompt
    ) -> (mask: CIImage, score: Float)? {
        let foregroundPoints: [CGPoint]
        if !prompt.foregroundPoints.isEmpty {
            // The bundled prompt encoder accepts one point per inference.
            // Run each positive point independently and union the masks so
            // later "保留" taps actually refine the visible range.
            foregroundPoints = prompt.foregroundPoints
        } else if let point = prompt.primaryForegroundPoint {
            foregroundPoints = [point]
        } else {
            return nil
        }

        guard let features = imageFeatures(for: image),
              let firstPoint = foregroundPoints.first,
              let firstForeground = maskWithScore(
                  features: features,
                  extent: image.extent,
                  at: firstPoint,
                  label: 1
              )
        else {
            return nil
        }

        var combined = firstForeground.mask
        var bestScore = firstForeground.score
        for foregroundPoint in foregroundPoints.dropFirst() {
            guard let foreground = maskWithScore(
                features: features,
                extent: image.extent,
                at: foregroundPoint,
                label: 1
            ) else {
                continue
            }
            combined = foreground.mask.applyingFilter("CIMaximumCompositing", parameters: [
                kCIInputBackgroundImageKey: combined
            ])
            bestScore = max(bestScore, foreground.score)
        }

        for backgroundPoint in prompt.backgroundPoints {
            guard let background = maskWithScore(
                features: features,
                extent: image.extent,
                at: backgroundPoint,
                label: 0
            ) else {
                continue
            }
            let invertedBackground = background.mask.applyingFilter("CIColorInvert")
            combined = combined.applyingFilter("CIMinimumCompositing", parameters: [
                kCIInputBackgroundImageKey: invertedBackground
            ])
        }
        return (combined.cropped(to: image.extent), bestScore)
    }

    /// Segment the object indicated by a normalized top-left-origin lasso.
    /// SAM2's Core ML prompt encoder is exported with a single positive point,
    /// so use the lasso's interior centroid as the foreground prompt.
    public func mask(
        for image: CIImage,
        in polygon: [CGPoint]
    ) -> CIImage? {
        guard let point = Self.promptPoint(in: polygon) else { return nil }
        return mask(for: image, at: point)
    }

    /// Same as `mask(for:at:)`, with the decoder confidence included.
    public func maskWithScore(
        for image: CIImage,
        at point: CGPoint
    ) -> (mask: CIImage, score: Float)? {
        maskWithScore(for: image, at: point, label: 1)
    }

    /// Same as `maskWithScore(for:at:)`, but allows a foreground (1) or
    /// background (0) point for correction prompts.
    public func maskWithScore(
        for image: CIImage,
        at point: CGPoint,
        label: Int32
    ) -> (mask: CIImage, score: Float)? {
        guard let features = imageFeatures(for: image) else { return nil }
        return maskWithScore(features: features, extent: image.extent, at: point, label: label)
    }

    private func imageFeatures(for image: CIImage) -> ImageFeatures? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let side = Self.inputSize
        guard let buffer = pixelBuffer(from: image, side: side) else { return nil }

        guard let encoderOutput = try? encoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["image": buffer])
        ),
        let imageEmbedding = encoderOutput.featureValue(for: "image_embedding")?.multiArrayValue,
        let featureS0 = encoderOutput.featureValue(for: "feats_s0")?.multiArrayValue,
        let featureS1 = encoderOutput.featureValue(for: "feats_s1")?.multiArrayValue else {
            return nil
        }
        return ImageFeatures(
            imageEmbedding: imageEmbedding,
            featureS0: featureS0,
            featureS1: featureS1
        )
    }

    private func maskWithScore(
        features: ImageFeatures,
        extent: CGRect,
        at point: CGPoint,
        label: Int32
    ) -> (mask: CIImage, score: Float)? {
        guard extent.width > 0, extent.height > 0,
              let points = try? MLMultiArray(shape: [1, 1, 2], dataType: .float32),
              let labels = try? MLMultiArray(shape: [1, 1], dataType: .int32) else {
            return nil
        }
        let side = Self.inputSize

        points[[0, 0, 0]] = NSNumber(value: Float(min(max(point.x, 0), 1)) * Float(side))
        points[[0, 0, 1]] = NSNumber(value: Float(min(max(point.y, 0), 1)) * Float(side))
        labels[[0, 0]] = NSNumber(value: label)

        guard let promptOutput = try? promptEncoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "points": points,
                "labels": labels
            ])
        ),
        let sparseEmbedding = promptOutput.featureValue(for: "sparse_embeddings")?.multiArrayValue,
        let denseEmbedding = promptOutput.featureValue(for: "dense_embeddings")?.multiArrayValue,
        let decoderOutput = try? decoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "image_embedding": features.imageEmbedding,
                "sparse_embedding": sparseEmbedding,
                "dense_embedding": denseEmbedding,
                "feats_s0": features.featureS0,
                "feats_s1": features.featureS1
            ])
        ),
        let masks = decoderOutput.featureValue(for: "low_res_masks")?.multiArrayValue,
        let scores = decoderOutput.featureValue(for: "scores")?.multiArrayValue else {
            return nil
        }

        var bestIndex = 0
        var bestScore = -Float.greatestFiniteMagnitude
        for index in 0..<scores.shape[1].intValue {
            let score = scores[[0, NSNumber(value: index)]].floatValue
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        guard let mask = maskImage(from: masks, index: bestIndex, extent: extent) else {
            return nil
        }
        return (mask, bestScore)
    }

    /// Returns an interior point for a normalized polygon using the standard
    /// signed-area centroid. A concave or malformed lasso falls back to the
    /// average of its vertices, then to its bounds' center.
    public static func promptPoint(in polygon: [CGPoint]) -> CGPoint? {
        guard polygon.count >= 3 else { return nil }
        var areaTwice: CGFloat = 0
        var centroidX: CGFloat = 0
        var centroidY: CGFloat = 0
        for index in polygon.indices {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            let cross = current.x * next.y - next.x * current.y
            areaTwice += cross
            centroidX += (current.x + next.x) * cross
            centroidY += (current.y + next.y) * cross
        }
        if abs(areaTwice) > 0.000001 {
            let centroid = CGPoint(
                x: centroidX / (3 * areaTwice),
                y: centroidY / (3 * areaTwice)
            )
            if pointIsInside(centroid, polygon: polygon) {
                return centroid
            }
        }

        let average = CGPoint(
            x: polygon.map(\.x).reduce(0, +) / CGFloat(polygon.count),
            y: polygon.map(\.y).reduce(0, +) / CGFloat(polygon.count)
        )
        if pointIsInside(average, polygon: polygon) {
            return average
        }

        let bounds = polygon.reduce(into: CGRect.null) { result, point in
            result = result.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        guard !bounds.isNull else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Estimate a normalized top-left-origin box from a decoded mask. The
    /// video path uses its center as the next SAM2 prompt so a moving subject
    /// does not have to remain under the original click.
    public func normalizedBounds(of mask: CIImage) -> CGRect? {
        let sampleSize = 128
        guard let image = ciContext.createCGImage(mask, from: mask.extent.integral) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleSize,
                height: sampleSize,
                bitsPerComponent: 8,
                bytesPerRow: sampleSize * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            return true
        }
        guard rendered else { return nil }

        var minX = sampleSize
        var minY = sampleSize
        var maxX = -1
        var maxY = -1
        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                let offset = (y * sampleSize + x) * 4
                guard pixels[offset] > 40 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let side = CGFloat(sampleSize)
        return CGRect(
            x: CGFloat(minX) / side,
            y: CGFloat(minY) / side,
            width: CGFloat(maxX - minX + 1) / side,
            height: CGFloat(maxY - minY + 1) / side
        )
    }

    private static func pointIsInside(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            let denominator = previous.y - current.y
            if crosses, abs(denominator) > 0.000001 {
                let x = (previous.x - current.x) * (point.y - current.y)
                    / denominator + current.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private func pixelBuffer(from image: CIImage, side: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        CVPixelBufferCreate(
            nil,
            side,
            side,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        guard let pixelBuffer else { return nil }

        let scaleX = CGFloat(side) / image.extent.width
        let scaleY = CGFloat(side) / image.extent.height
        let scaled = image
            .transformed(by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            ))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaled, to: pixelBuffer)
        return pixelBuffer
    }

    private func maskImage(
        from masks: MLMultiArray,
        index: Int,
        extent: CGRect
    ) -> CIImage? {
        guard masks.shape.count >= 4 else { return nil }
        let side = masks.shape[2].intValue
        guard side > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side)

        let channelStride = masks.strides[1].intValue
        let rowStride = masks.strides[2].intValue
        let columnStride = masks.strides[3].intValue
        let channelBase = index * channelStride
        func write(_ valueAt: (Int) -> Float) {
            for y in 0..<side {
                let rowBase = channelBase + y * rowStride
                for x in 0..<side {
                    // The exported decoder returns logits. Decode them with a
                    // sigmoid instead of treating the logits as brightness;
                    // the latter creates clipped islands and strong speckles.
                    let logit = valueAt(rowBase + x * columnStride)
                    let probability = 1 / (1 + exp(-logit))
                    let value = probability < 0.35
                        ? 0
                        : min(1, (probability - 0.35) / 0.65)
                    bytes[y * side + x] = UInt8(value * 255)
                }
            }
        }

        switch masks.dataType {
        case .float32:
            let pointer = masks.dataPointer.bindMemory(to: Float32.self, capacity: masks.count)
            write { Float(pointer[$0]) }
        case .float16:
            let pointer = masks.dataPointer.bindMemory(to: Float16.self, capacity: masks.count)
            write { Float(pointer[$0]) }
        default:
            for y in 0..<side {
                for x in 0..<side {
                    let logit = masks[[
                        0,
                        NSNumber(value: index),
                        NSNumber(value: y),
                        NSNumber(value: x)
                    ]].floatValue
                    let probability = 1 / (1 + exp(-logit))
                    let value = probability < 0.35
                        ? 0
                        : min(1, (probability - 0.35) / 0.65)
                    bytes[y * side + x] = UInt8(value * 255)
                }
            }
        }

        guard let cgImage = bytes.withUnsafeMutableBytes({ buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            return context.makeImage()
        }) else { return nil }

        let base = CIImage(cgImage: cgImage)
        let scale = extent.height / CGFloat(side)
        let aspect = extent.width / extent.height
        let upscaled = base.applyingFilter("CILanczosScaleTransform", parameters: [
            "inputScale": scale,
            "inputAspectRatio": aspect
        ])
        return upscaled
            // Close tiny holes and isolated one-pixel fragments introduced by
            // the low-resolution decoder before the mask is used for video.
            .applyingFilter("CIMorphologyMaximum", parameters: [
                "inputRadius": 1.0
            ])
            .applyingFilter("CIMorphologyMinimum", parameters: [
                "inputRadius": 1.0
            ])
            .transformed(by: CGAffineTransform(
                translationX: extent.minX - upscaled.extent.minX,
                y: extent.minY - upscaled.extent.minY
            ))
            .cropped(to: extent)
    }
}
