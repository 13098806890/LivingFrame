import LivingFrameCore
import SwiftUI

/// Shows each sticker style rendered on a representative frame from the selected cutout.
struct StickerStyleOptionPicker: View {
    let clip: SegmentedClip
    let element: CompositionElement
    let composition: Composition
    let currentTime: TimeInterval
    let selectedStyle: StickerStyle
    let onSelect: (StickerStyle) -> Void

    @State private var thumbnails: [String: CGImage] = [:]
    @State private var isLoading = false

    private var frameIndex: Int {
        if let frameIndex = CompositionRenderer.optionPreviewFrameIndex(
            for: element,
            in: composition,
            at: currentTime
        ) {
            return frameIndex
        }
        let frameIndices = clip.playbackFrameIndices
        guard !frameIndices.isEmpty else { return 0 }
        let fps = clip.fps.isFinite && clip.fps > 0 ? clip.fps : 1
        let sourceTime = element.sourceStartTime.isFinite ? max(element.sourceStartTime, 0) : 0
        let lastOffset = Double(frameIndices.count - 1)
        let boundedOffset = min(max(sourceTime * fps, 0), lastOffset)
        return frameIndices[Int(boundedOffset)]
    }

    private var thumbnailSetKey: String {
        [
            clip.id,
            String(frameIndex),
            clip.cropCacheKey,
            String(clip.normalizedRotationQuarterTurns),
            clip.edgeStyle.rawValue,
            clip.edgeLineStyle.rawValue,
            clip.edgeThickness.rawValue,
            clip.edgeColorHex.uppercased()
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("风格")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StickerStyle.allCases) { style in
                        styleOption(style)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .task(id: thumbnailSetKey) {
            await loadThumbnails()
        }
    }

    private func styleOption(_ style: StickerStyle) -> some View {
        let isSelected = selectedStyle == style
        return Button {
            onSelect(style)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    CheckerboardView()
                        .opacity(0.72)

                    if let image = thumbnails[style.rawValue] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "person.crop.rectangle")
                            .font(.title3)
                            .foregroundStyle(LF.textSecondary)
                    }
                }
                .frame(width: 66, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(LF.brandTint.opacity(0.2), lineWidth: 1)
                }

                Text(style.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? LF.selectionText : LF.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            }
            .padding(7)
            .frame(width: 82, height: 104)
            .background(
                isSelected ? LF.selectionFill : LF.surface2.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.16),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @MainActor
    private func loadThumbnails() async {
        var result: [String: CGImage] = [:]
        let missingStyles = StickerStyle.allCases.filter { style in
            let key = cacheKey(for: style)
            if let image = StickerStylePreviewCache.image(for: key) {
                result[style.rawValue] = image
                return false
            }
            return true
        }

        thumbnails = result
        guard !missingStyles.isEmpty else {
            isLoading = false
            return
        }

        isLoading = true
        let clipValue = clip
        let frameIndexValue = frameIndex
        let styles = missingStyles.map(\.rawValue)
        let worker = Task.detached(priority: .utility) {
            let renderer = CompositionRenderer(
                frameMaxPixelSize: 144,
                backgroundMediaProvider: BackgroundStore.shared
            )
            var rendered: [String: CGImage] = [:]
            for styleID in styles {
                guard !Task.isCancelled,
                      let style = StickerStyle(rawValue: styleID) else { break }
                if let image = autoreleasepool(invoking: {
                    renderer.stickerStyleThumbnail(
                        for: clipValue,
                        frameIndex: frameIndexValue,
                        style: style
                    )
                }) {
                    rendered[styleID] = image
                }
            }
            return rendered
        }

        let generated = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }

        for (styleID, image) in generated {
            let key = cacheKey(for: styleID)
            StickerStylePreviewCache.insert(image, for: key)
            result[styleID] = image
        }
        thumbnails = result
        isLoading = false
    }

    private func cacheKey(for style: StickerStyle) -> String {
        cacheKey(for: style.rawValue)
    }

    private func cacheKey(for styleID: String) -> String {
        "\(thumbnailSetKey)|\(styleID)"
    }
}

private final class StickerStylePreviewImage: NSObject {
    let cgImage: CGImage

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

private enum StickerStylePreviewCache {
    private static let storage: NSCache<NSString, StickerStylePreviewImage> = {
        let cache = NSCache<NSString, StickerStylePreviewImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func image(for key: String) -> CGImage? {
        storage.object(forKey: key as NSString)?.cgImage
    }

    static func insert(_ image: CGImage, for key: String) {
        let cost = image.bytesPerRow * image.height
        storage.setObject(StickerStylePreviewImage(image), forKey: key as NSString, cost: cost)
    }
}
