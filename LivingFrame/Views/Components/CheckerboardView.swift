import SwiftUI

/// 棋盘格背景：衬托透明区域（专业抠图工具的惯例）
struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 12
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    let light = (row + col) % 2 == 0
                    context.fill(
                        Path(CGRect(x: x, y: y, width: step, height: step)),
                        with: .color(light ? .white : Color(white: 0.85))
                    )
                    x += step
                    col += 1
                }
                y += step
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}
