import SwiftUI

/// Export watermark notice shared by composition export and asset extraction.
struct WatermarkNoticeCard: View {
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "seal.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LF.actionPrimary)
                    .frame(width: 38, height: 38)
                    .background(LF.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("免费导出会在右下角添加 GIFBloom 水印。")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LF.textPrimary)
                    Text("订阅 GIFBloom Pro 后可去除导出水印。")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onSubscribe) {
                Text("订阅去水印")
                    .frame(maxWidth: .infinity)
            }
            .lfActionButtonStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [LF.selectionFill.opacity(0.9), LF.brandTint.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LF.actionPrimary.opacity(0.48), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
