import LivingFrameCore
import SwiftUI

/// 拼接媒体缩略图：选择器与素材库共用，保证预览和动态标识一致。
struct BackgroundAssetCell: View {
    let item: BackgroundMediaItem
    let isSelected: Bool
    let onSelect: () -> Void
    var showsSelection = true

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = BackgroundStore.shared.loadFrame(named: item.id, at: 0) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.black.opacity(0.2)
                    }
                }
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if item.isAnimated {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.42), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(4)
                }

                if showsSelection {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? LF.header : .white.opacity(0.88))
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if showsSelection {
                    onSelect()
                }
            }

            HStack(spacing: 4) {
                Text(item.isAnimated ? "动态素材" : "静态素材")
                if item.isAnimated {
                    Text("\(String(format: "%.1fs", item.duration))")
                        .foregroundStyle(LF.textSecondary)
                }
            }
            .font(.caption2)
            .foregroundStyle(LF.textPrimary)
            .lineLimit(1)
        }
    }
}

struct AssetCell: View {
    let clip: SegmentedClip
    let onSelect: () -> Void
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 4) {
            AnimatedClipPreview(clip: clip, maxPixelSize: 320, isPlaying: $isPlaying)
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    ClipPreviewPlayButton(clip: clip, isPlaying: $isPlaying)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }

            Text(clip.name)
                .font(.caption2)
                .foregroundStyle(LF.textPrimary)
                .lineLimit(1)
        }
    }
}
