import LivingFrameCore
import SwiftUI

/// Filter choices shown as small previews of the selected element's current frame.
struct ElementFilterOptionPicker: View {
    let element: CompositionElement
    let composition: Composition
    let currentTime: TimeInterval
    let previewRevision: Int
    let selectedFilter: ElementFilter
    let onSelect: (ElementFilter) -> Void

    @State private var thumbnails: [String: CGImage] = [:]
    @State private var isLoading = false

    private var previewKey: String {
        let fps = composition.fps.isFinite && composition.fps > 0 ? composition.fps : 30
        let relativeTime = max(currentTime - element.startTime, 0)
        let timelineFrame = Int((relativeTime * fps).rounded(.down))
        let frame = CompositionRenderer.optionPreviewFrameIndex(
            for: element,
            in: composition,
            at: currentTime
        ) ?? timelineFrame
        let sourceID: String
        switch element.kind {
        case .clip(let id), .background(let id), .decoration(let id), .effect(let id), .text(let id):
            sourceID = id
        case .collage(let id):
            sourceID = id.uuidString
        case .canvasEdge:
            sourceID = "canvas-edge"
        }
        return [
            element.id.uuidString,
            sourceID,
            String(frame),
            String(element.startTime),
            String(element.endTime),
            String(element.sourceStartTime),
            String(element.sourceEndTime),
            String(element.sourcePlaybackOffset ?? 0),
            element.playbackCount.map { String($0) } ?? "implicit",
            "\(composition.canvas.width)x\(composition.canvas.height)",
            String(previewRevision)
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("滤镜")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ElementFilter.allCases) { filter in
                        filterOption(filter)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .task(id: previewKey) {
            await loadThumbnails()
        }
    }

    private func filterOption(_ filter: ElementFilter) -> some View {
        let isSelected = selectedFilter == filter
        return Button {
            onSelect(filter)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    CheckerboardView()
                        .opacity(0.72)

                    if let image = thumbnails[filter.rawValue] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "camera.filters")
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

                Text(filter.title)
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
        .accessibilityLabel(filter.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @MainActor
    private func loadThumbnails() async {
        var result: [String: CGImage] = [:]
        let missingFilters = ElementFilter.allCases.filter { filter in
            let key = cacheKey(for: filter)
            if let image = ElementFilterPreviewCache.image(for: key) {
                result[filter.rawValue] = image
                return false
            }
            return true
        }

        thumbnails = result
        guard !missingFilters.isEmpty else {
            isLoading = false
            return
        }

        isLoading = true
        let elementValue = element
        let compositionValue = composition
        let timeValue = currentTime
        let filters = missingFilters
        let worker = Task.detached(priority: .utility) {
            let renderer = CompositionRenderer(
                frameMaxPixelSize: 144,
                backgroundMediaProvider: BackgroundStore.shared
            )
            var rendered: [String: CGImage] = [:]
            for filter in filters {
                guard !Task.isCancelled else { break }
                if let image = autoreleasepool(invoking: {
                    renderer.elementFilterThumbnail(
                        for: elementValue,
                        in: compositionValue,
                        at: timeValue,
                        filter: filter
                    )
                }) {
                    rendered[filter.rawValue] = image
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

        for (filterID, image) in generated {
            let key = "\(previewKey)|\(filterID)"
            ElementFilterPreviewCache.insert(image, for: key)
            result[filterID] = image
        }
        thumbnails = result
        isLoading = false
    }

    private func cacheKey(for filter: ElementFilter) -> String {
        "\(previewKey)|\(filter.rawValue)"
    }
}

private final class ElementFilterPreviewImage: NSObject {
    let cgImage: CGImage

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

private enum ElementFilterPreviewCache {
    private static let storage: NSCache<NSString, ElementFilterPreviewImage> = {
        let cache = NSCache<NSString, ElementFilterPreviewImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func image(for key: String) -> CGImage? {
        storage.object(forKey: key as NSString)?.cgImage
    }

    static func insert(_ image: CGImage, for key: String) {
        let cost = image.bytesPerRow * image.height
        storage.setObject(ElementFilterPreviewImage(image), forKey: key as NSString, cost: cost)
    }
}
