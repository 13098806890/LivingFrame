import CoreGraphics

/// 创建一次性程序化位图的公共入口。
///
/// 纸张、描边等效果都通过这里生成静态 CGImage，避免各效果重复维护
/// bitmap context，也避免把 Core Graphics 绘制带进逐帧播放热路径。
enum ProceduralRasterRenderer {
    static func makeImage(
        size: CGSize,
        transparent: Bool = true,
        draw: (CGContext, CGRect) -> Void
    ) -> CGImage? {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        if transparent {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        }
        draw(context, CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
