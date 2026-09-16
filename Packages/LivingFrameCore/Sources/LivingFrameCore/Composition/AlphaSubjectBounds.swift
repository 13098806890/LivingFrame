import CoreGraphics

/// Shared alpha-boundary calculation for segmented subjects.
///
/// Segmentation keeps the original frame canvas, so the subject can be surrounded
/// by transparent pixels.  Preview tiles and clip effects must use the same
/// definition of "visible subject" when deciding how large the subject is.
internal enum AlphaSubjectBounds {
    static let defaultAlphaThreshold: UInt8 = 24

    static func visiblePixelBounds(
        in image: CGImage,
        alphaThreshold: UInt8 = defaultAlphaThreshold
    ) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let didRender = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didRender else { return nil }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width where pixels[rowStart + x * 4 + 3] > alphaThreshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    static func subjectBase(
        in canvas: CGRect,
        bounds: CGRect?
    ) -> CGFloat {
        let usableBounds = (bounds ?? canvas).intersection(canvas)
        guard usableBounds.width > 0, usableBounds.height > 0 else {
            return min(canvas.width, canvas.height)
        }
        return min(usableBounds.width, usableBounds.height)
    }
}
