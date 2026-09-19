import AppKit
import Foundation

private let W: CGFloat = 1080
private let H: CGFloat = 1440
private let ink = NSColor(calibratedRed: 0.09, green: 0.18, blue: 0.25, alpha: 1)
private let muted = NSColor(calibratedRed: 0.34, green: 0.42, blue: 0.47, alpha: 1)
private let blue = NSColor(calibratedRed: 0.16, green: 0.59, blue: 0.82, alpha: 1)
private let paleBlue = NSColor(calibratedRed: 0.86, green: 0.95, blue: 0.99, alpha: 1)
private let orange = NSColor(calibratedRed: 0.98, green: 0.36, blue: 0.16, alpha: 1)
private let paleOrange = NSColor(calibratedRed: 1.00, green: 0.91, blue: 0.86, alpha: 1)
private let cream = NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.94, alpha: 1)
private let green = NSColor(calibratedRed: 0.20, green: 0.61, blue: 0.48, alpha: 1)

private struct Card {
    let eyebrow: String
    let title: String
    let subtitle: String
    let bullets: [String]
    let kind: Int
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: H - y - h, width: w, height: h)
}

private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    let name: String
    switch weight {
    case .bold, .heavy, .black, .semibold: name = "PingFangSC-Semibold"
    default: name = "PingFangSC-Regular"
    }
    return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}

private func text(_ value: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                  size: CGFloat, color: NSColor = ink, weight: NSFont.Weight = .regular,
                  alignment: NSTextAlignment = .left, lineSpacing: CGFloat = 7) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = lineSpacing
    paragraph.paragraphSpacing = 0
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font(size, weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    (value as NSString).draw(in: rect(x, y, w, h), withAttributes: attributes)
}

private func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, line: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = line
        path.stroke()
    }
}

private func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
                  color: NSColor, width: CGFloat = 3) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x1, y: H - y1))
    path.line(to: NSPoint(x: x2, y: H - y2))
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

private func circle(_ cx: CGFloat, _ cy: CGFloat, _ diameter: CGFloat, fill: NSColor,
                    stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(ovalIn: rect(cx - diameter / 2, cy - diameter / 2, diameter, diameter))
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

private func capsule(_ label: String, x: CGFloat, y: CGFloat, w: CGFloat,
                     fill: NSColor = paleBlue, color: NSColor = blue) {
    rounded(x, y, w, 54, radius: 27, fill: fill)
    text(label, x: x + 20, y: y + 10, w: w - 40, h: 36, size: 24,
         color: color, weight: .semibold, alignment: .center, lineSpacing: 0)
}

private func loadImage(_ path: String) -> NSImage? { NSImage(contentsOfFile: path) }

private func drawImage(_ image: NSImage, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                       roundedRadius: CGFloat? = nil, fit: Bool = true) {
    NSGraphicsContext.saveGraphicsState()
    if let roundedRadius {
        NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: roundedRadius, yRadius: roundedRadius).addClip()
    }
    let source = image.size
    var target = rect(x, y, w, h)
    if fit {
        let ratio = min(w / source.width, h / source.height)
        let dw = source.width * ratio
        let dh = source.height * ratio
        target = rect(x + (w - dw) / 2, y + (h - dh) / 2, dw, dh)
    }
    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
               respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}

private func setup(_ background: NSImage) {
    NSColor.white.setFill()
    NSBezierPath(rect: rect(0, 0, W, H)).fill()
    drawImage(background, x: 0, y: 0, w: W, h: H, fit: false)
}

private func masthead(_ number: String) {
    text("GIFBloom  /  开发手记", x: 78, y: 64, w: 510, h: 42,
         size: 25, color: ink, weight: .semibold, lineSpacing: 0)
    rounded(78, 116, 66, 7, radius: 4, fill: orange)
    text(number, x: 830, y: 67, w: 170, h: 36,
         size: 21, color: muted, weight: .medium, alignment: .right, lineSpacing: 0)
}

private func bullets(_ rows: [String]) {
    var y: CGFloat = 491
    for row in rows {
        circle(105, y + 19, 13, fill: orange)
        text(row, x: 136, y: y, w: 824, h: 102, size: 27, color: ink, lineSpacing: 7)
        y += 126
    }
}

private func diagramLibrary() {
    rounded(90, 918, 900, 326, radius: 34, fill: NSColor.white.withAlphaComponent(0.76),
            stroke: NSColor.white, line: 2)
    text("多选素材", x: 138, y: 958, w: 180, h: 34, size: 22,
         color: muted, weight: .semibold, lineSpacing: 0)
    let colors = [paleBlue, paleOrange, NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.88, alpha: 1), paleOrange]
    for i in 0..<4 {
        let x = CGFloat(140 + i * 112)
        rounded(x, 1020, 92, 112, radius: 16, fill: colors[i], stroke: NSColor.white, line: 2)
        circle(x + 72, 1044, 28, fill: i < 3 ? blue : orange)
        text("✓", x: x + 58, y: 1032, w: 28, h: 28, size: 19, color: .white,
             weight: .bold, alignment: .center, lineSpacing: 0)
        rounded(x + 16, 1083, 58, 7, radius: 4, fill: NSColor.white.withAlphaComponent(0.9))
        rounded(x + 16, 1099, 43, 6, radius: 3, fill: NSColor.white.withAlphaComponent(0.7))
    }
    line(610, 1074, 716, 1074, color: orange, width: 5)
    line(700, 1058, 718, 1074, color: orange, width: 5)
    line(700, 1090, 718, 1074, color: orange, width: 5)
    rounded(754, 1006, 176, 136, radius: 20, fill: paleBlue)
    text("文件夹", x: 774, y: 1054, w: 136, h: 36, size: 25,
         color: blue, weight: .semibold, alignment: .center, lineSpacing: 0)
    text("选完再统一导入", x: 136, y: 1169, w: 380, h: 32,
         size: 22, color: muted, lineSpacing: 0)
    text("移出文件夹 ≠ 删除原件", x: 600, y: 1169, w: 330, h: 32,
         size: 22, color: muted, alignment: .right, lineSpacing: 0)
}

private func diagramCanvas() {
    rounded(90, 918, 900, 326, radius: 34, fill: NSColor.white.withAlphaComponent(0.76),
            stroke: NSColor.white, line: 2)
    text("一套纹理控件", x: 132, y: 956, w: 300, h: 34, size: 22,
         color: muted, weight: .semibold, lineSpacing: 0)
    rounded(132, 1014, 355, 162, radius: 22, fill: paleBlue)
    for i in 0..<5 {
        line(164, CGFloat(1046 + i * 23), 455, CGFloat(1046 + i * 23), color: blue.withAlphaComponent(0.65), width: 3)
    }
    text("平行线", x: 157, y: 1185, w: 125, h: 30, size: 21, color: blue,
         weight: .semibold, lineSpacing: 0)
    text("马赛克", x: 326, y: 1185, w: 125, h: 30, size: 21, color: blue,
         weight: .semibold, alignment: .right, lineSpacing: 0)
    rounded(542, 1014, 386, 162, radius: 22, fill: cream)
    // Two preview subjects share the same framing scale.
    for x in [CGFloat(624), CGFloat(802)] {
        rounded(x - 62, 1030, 124, 122, radius: 18, fill: NSColor.white)
        circle(x, 1062, 32, fill: orange)
        rounded(x - 28, 1082, 56, 53, radius: 22, fill: blue)
    }
    text("风格 / 滤镜预览", x: 569, y: 1185, w: 335, h: 30,
         size: 21, color: muted, alignment: .center, lineSpacing: 0)
}

private func diagramExport() {
    rounded(90, 918, 900, 326, radius: 34, fill: NSColor.white.withAlphaComponent(0.76),
            stroke: NSColor.white, line: 2)
    let centers: [CGFloat] = [250, 540, 830]
    let labels = ["剪影素材", "裁剪 / 旋转", "透明 GIF"]
    for i in 0..<3 {
        let x = centers[i]
        rounded(x - 100, 986, 200, 164, radius: 26,
                fill: i == 2 ? paleBlue : (i == 1 ? paleOrange : cream),
                stroke: NSColor.white, line: 2)
        if i == 0 {
            circle(x, 1030, 42, fill: orange)
            rounded(x - 36, 1051, 72, 74, radius: 28, fill: blue)
        } else if i == 1 {
            rounded(x - 53, 1014, 106, 78, radius: 8, fill: NSColor.white, stroke: orange, line: 3)
            line(x - 69, 1001, x - 69, 1030, color: orange, width: 5)
            line(x - 69, 1001, x - 39, 1001, color: orange, width: 5)
            line(x + 69, 1105, x + 69, 1076, color: orange, width: 5)
            line(x + 69, 1105, x + 39, 1105, color: orange, width: 5)
        } else {
            for row in 0..<4 { for col in 0..<4 {
                let c: NSColor = (row + col).isMultiple(of: 2) ? NSColor.white : NSColor(calibratedWhite: 0.82, alpha: 1)
                NSBezierPath(rect: rect(x - 42 + CGFloat(col) * 21, 1011 + CGFloat(row) * 21, 21, 21)).fill()
                c.setFill()
                NSBezierPath(rect: rect(x - 42 + CGFloat(col) * 21, 1011 + CGFloat(row) * 21, 21, 21)).fill()
            }}
            circle(x, 1053, 32, fill: orange)
            rounded(x - 25, 1068, 50, 52, radius: 20, fill: blue)
        }
        text(labels[i], x: x - 110, y: 1166, w: 220, h: 34, size: 22,
             color: ink, weight: .semibold, alignment: .center, lineSpacing: 0)
        if i < 2 {
            line(x + 115, 1066, x + 167, 1066, color: muted.withAlphaComponent(0.55), width: 3)
            line(x + 153, 1057, x + 167, 1066, color: muted.withAlphaComponent(0.55), width: 3)
            line(x + 153, 1075, x + 167, 1066, color: muted.withAlphaComponent(0.55), width: 3)
        }
    }
}

private func diagramQuality() {
    rounded(90, 918, 900, 326, radius: 34, fill: NSColor.white.withAlphaComponent(0.76),
            stroke: NSColor.white, line: 2)
    rounded(130, 968, 360, 146, radius: 23, fill: cream, stroke: NSColor(calibratedWhite: 0.90, alpha: 1), line: 2)
    rounded(532, 968, 416, 146, radius: 23, fill: paleBlue, stroke: NSColor(calibratedWhite: 0.90, alpha: 1), line: 2)
    text("草稿", x: 162, y: 990, w: 100, h: 34, size: 22, color: muted, weight: .semibold, lineSpacing: 0)
    text("自动保存", x: 162, y: 1042, w: 210, h: 42, size: 31, color: ink, weight: .bold, lineSpacing: 0)
    text("正式作品", x: 566, y: 990, w: 150, h: 34, size: 22, color: blue, weight: .semibold, lineSpacing: 0)
    text("手动保存", x: 566, y: 1042, w: 220, h: 42, size: 31, color: ink, weight: .bold, lineSpacing: 0)
    circle(438, 1042, 34, fill: green)
    text("✓", x: 423, y: 1026, w: 30, h: 30, size: 20, color: .white, weight: .bold, alignment: .center, lineSpacing: 0)
    text("iPhone 17 Pro Max 定向回归", x: 142, y: 1153, w: 470, h: 32,
         size: 21, color: muted, lineSpacing: 0)
    capsule("7 / 7 通过", x: 700, y: 1135, w: 210, fill: paleBlue, color: green)
}

// Render one page at a time into a transparent bitmap context, then export PNG.
private var currentRep: NSBitmapImageRep!
private func beginPage() {
    currentRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: currentRep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
}

private func endPage(_ url: URL) throws {
    NSGraphicsContext.restoreGraphicsState()
    guard let data = currentRep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GIFBloomCards", code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

private func renderPage(_ body: () throws -> Void, to url: URL) throws {
    beginPage()
    try body()
    try endPage(url)
}

private func coverPage(background: NSImage, icon: NSImage, to url: URL) throws {
    try renderPage({
        setup(background)
        masthead("09.09 — 09.15")
        rounded(422, 198, 236, 236, radius: 56, fill: NSColor.white.withAlphaComponent(0.70),
                stroke: NSColor.white.withAlphaComponent(0.9), line: 2)
        drawImage(icon, x: 440, y: 216, w: 200, h: 200, roundedRadius: 42)
        text("我在做一个 iOS App", x: 92, y: 494, w: 896, h: 56,
             size: 30, color: blue, weight: .semibold, alignment: .center, lineSpacing: 0)
        text("把视频里的瞬间，\n做成会动的透明贴纸", x: 84, y: 574, w: 912, h: 240,
             size: 69, color: ink, weight: .bold, alignment: .center, lineSpacing: 12)
        text("GIFBloom · 独立开发进度记录", x: 130, y: 852, w: 820, h: 48,
             size: 27, color: muted, alignment: .center, lineSpacing: 0)
        capsule("人物剪影", x: 140, y: 970, w: 220, fill: paleBlue, color: blue)
        capsule("时间轴编辑", x: 430, y: 970, w: 220, fill: paleOrange, color: orange)
        capsule("透明 GIF", x: 720, y: 970, w: 220, fill: paleBlue, color: blue)
        rounded(164, 1107, 752, 2, radius: 1, fill: NSColor(calibratedWhite: 0.78, alpha: 0.55))
        text("最近几天，把素材管理、裁剪导出和稳定性又打磨了一轮。",
             x: 132, y: 1150, w: 816, h: 82, size: 25, color: muted,
             alignment: .center, lineSpacing: 8)
        text("向左滑，看看这次更新了什么  →", x: 180, y: 1284, w: 720, h: 40,
             size: 22, color: orange, weight: .semibold, alignment: .center, lineSpacing: 0)
    }, to: url)
}

private func featurePage(_ card: Card, index: Int, background: NSImage, to url: URL) throws {
    try renderPage({
        setup(background)
        masthead(String(format: "%02d / 04", index))
        capsule(card.eyebrow, x: 78, y: 173, w: CGFloat(max(174, card.eyebrow.count * 32 + 52)),
                fill: card.kind.isMultiple(of: 2) ? paleBlue : paleOrange,
                color: card.kind.isMultiple(of: 2) ? blue : orange)
        text(card.title, x: 78, y: 260, w: 924, h: 154, size: 57,
             color: ink, weight: .bold, lineSpacing: 8)
        text(card.subtitle, x: 82, y: 414, w: 914, h: 65, size: 25,
             color: muted, lineSpacing: 6)
        bullets(card.bullets)
        switch card.kind {
        case 1: diagramLibrary()
        case 2: diagramCanvas()
        case 3: diagramExport()
        default: diagramQuality()
        }
        rounded(82, 1294, 916, 2, radius: 1, fill: NSColor(calibratedWhite: 0.72, alpha: 0.58))
        text(card.kind == 4 ? "下一次，继续记录把细节磨好的过程。" : "GIFBloom · 还在认真打磨中",
             x: 90, y: 1320, w: 900, h: 36, size: 21, color: muted,
             alignment: .center, lineSpacing: 0)
    }, to: url)
}

let args = CommandLine.arguments
guard args.count == 4 else {
    fputs("Usage: make_cards.swift <background.png> <app-icon.png> <output-directory>\n", stderr)
    exit(2)
}
let backgroundURL = URL(fileURLWithPath: args[1])
let iconURL = URL(fileURLWithPath: args[2])
let outputDirectory = URL(fileURLWithPath: args[3], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
guard let background = loadImage(backgroundURL.path), let icon = loadImage(iconURL.path) else {
    fatalError("Could not load the background or app icon")
}

private let cards = [
    Card(eyebrow: "素材库", title: "素材多了，\n整理也得跟上", subtitle: "把批量操作补齐，也把“移除”和“删除”分清楚。", bullets: [
        "提取、拼接素材现在都能一次多选，选完再统一导入。",
        "文件夹支持批量添加 / 移除；移出归属不会删掉原件。",
        "作品还在引用的素材会受到保护，减少误删。"
    ], kind: 1),
    Card(eyebrow: "编辑体验", title: "画布设置和预览，\n终于说同一种语言", subtitle: "这次重点不是加新花样，而是让看见的效果更一致。", bullets: [
        "画布、检查器和素材背景共用平行线 / 马赛克控件。",
        "风格与滤镜缩略图统一当前帧、主体范围和缩放比例。",
        "中文“剪影”与英文 Cutout 的用语也统一到了全流程。"
    ], kind: 2),
    Card(eyebrow: "剪影导出", title: "从剪影到透明 GIF，\n中间这步补完整了", subtitle: "素材详情页现在可以直接完成最后一轮整理。", bullets: [
        "详情页支持裁剪与 90° 旋转，预览、编辑和导出保持一致。",
        "导出规格按源素材过滤，不会提供超出素材能力的尺寸 / 帧率。",
        "导出后自动保存到相册；编辑器效果不会污染原始剪影。"
    ], kind: 3),
    Card(eyebrow: "稳定性", title: "保存更稳，\n回归也更有章法", subtitle: "不只把功能做出来，也把容易踩的边界认真收好。", bullets: [
        "正式作品改为手动保存，编辑中的内容单独作为草稿自动保存。",
        "导出帧率有 10 / 15 / 30 / 60 fps 档位，并受源素材限制。",
        "提取页与超大字体布局完成定向回归：7 项检查全部通过。"
    ], kind: 4)
]

try coverPage(background: background, icon: icon, to: outputDirectory.appendingPathComponent("01-cover.png"))
for (offset, card) in cards.enumerated() {
    try featurePage(card, index: offset + 1, background: background,
                    to: outputDirectory.appendingPathComponent(String(format: "%02d-%@.png", offset + 2, ["library", "editor", "export", "quality"][offset])))
}
print("Created 5 Xiaohongshu cards in \(outputDirectory.path)")
