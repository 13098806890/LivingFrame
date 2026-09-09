import CoreImage
import CoreGraphics

/// 兼容旧调用方的存储适配器。渲染器本身只依赖 BackgroundMediaProviding，
/// 后续预览或导出可以直接注入内存快照，避免逐帧访问磁盘元数据。
public extension CompositionRenderer {
    init(
        context: CIContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]),
        frameMaxPixelSize: CGFloat? = nil,
        isPlaybackReversed: Bool = false
    ) {
        self.init(
            context: context,
            frameMaxPixelSize: frameMaxPixelSize,
            isPlaybackReversed: isPlaybackReversed,
            backgroundMediaProvider: BackgroundStore.shared
        )
    }
}
