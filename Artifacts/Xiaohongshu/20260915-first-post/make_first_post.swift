import AppKit
import Foundation

private let canvasW: CGFloat = 1080
private let canvasH: CGFloat = 1440
private let dark = NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.25, alpha: 1)
private let gray = NSColor(calibratedRed: 0.34, green: 0.43, blue: 0.49, alpha: 1)
private let blue = NSColor(calibratedRed: 0.16, green: 0.59, blue: 0.82, alpha: 1)
private let lightBlue = NSColor(calibratedRed: 0.87, green: 0.95, blue: 0.99, alpha: 1)
private let orange = NSColor(calibratedRed: 0.98, green: 0.36, blue: 0.16, alpha: 1)
private let lightOrange = NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.88, alpha: 1)
private let cream = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.94, alpha: 1)

private func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: canvasH - top - h, width: w, height: h)
}

private func typeface(_ size: CGFloat, bold: Bool = false) -> NSFont {
    let name = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
    return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
}

private func drawText(_ value: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                      size: CGFloat, color: NSColor = dark, bold: Bool = false,
                      align: NSTextAlignment = .left, spacing: CGFloat = 8) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = align
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = spacing
    let attrs: [NSAttributedString.Key: Any] = [
        .font: typeface(size, bold: bold),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    (value as NSString).draw(in: rect(x, y, w, h), withAttributes: attrs)
}

private func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                       radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, width: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = width
        path.stroke()
    }
}

private func drawLine(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
                      color: NSColor, width: CGFloat = 3) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x1, y: canvasH - y1))
    path.line(to: NSPoint(x: x2, y: canvasH - y2))
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

private func drawCircle(_ cx: CGFloat, _ cy: CGFloat, _ d: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: rect(cx - d / 2, cy - d / 2, d, d)).fill()
}

private func drawPill(_ title: String, x: CGFloat, y: CGFloat, w: CGFloat,
                      fill: NSColor, color: NSColor) {
    roundRect(x, y, w, 54, radius: 27, fill: fill)
    drawText(title, x: x + 12, y: y + 10, w: w - 24, h: 34,
             size: 22, color: color, bold: true, align: .center, spacing: 0)
}

private func addStickerSpace(x: CGFloat = 718, y: CGFloat = 965) {
    // Low-contrast checkerboard makes the empty slot read as a transparent-GIF preview area.
    roundRect(x, y, 270, 300, radius: 28,
              fill: lightBlue.withAlphaComponent(0.55),
              stroke: blue.withAlphaComponent(0.22), width: 2)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect(x, y, 270, 300), xRadius: 28, yRadius: 28).addClip()
    let cell: CGFloat = 30
    for row in 0..<10 {
        for col in 0..<9 {
            if (row + col).isMultiple(of: 2) {
                let fill = NSColor(calibratedWhite: 0.70, alpha: 0.26)
                fill.setFill()
                NSBezierPath(rect: rect(x + 0.5 + CGFloat(col) * cell,
                                        y + 0.5 + CGFloat(row) * cell,
                                        cell, cell)).fill()
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}

private var bitmap: NSBitmapImageRep!
private func beginPage() {
    bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvasW), pixelsHigh: Int(canvasH),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
}

private func endPage(_ url: URL) throws {
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GIFBloomFirstPost", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try data.write(to: url)
}

private func withPage(_ url: URL, draw: () throws -> Void) throws {
    beginPage()
    try draw()
    try endPage(url)
}

private func place(_ image: NSImage, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                   radius: CGFloat? = nil) {
    NSGraphicsContext.saveGraphicsState()
    if let radius {
        NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius, yRadius: radius).addClip()
    }
    image.draw(in: rect(x, y, w, h), from: .zero, operation: .sourceOver, fraction: 1,
               respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}

private func background(_ image: NSImage) {
    image.draw(in: rect(0, 0, canvasW, canvasH), from: .zero,
               operation: .sourceOver, fraction: 1, respectFlipped: true,
               hints: [.interpolation: NSImageInterpolation.high])
}

private func masthead(_ number: String) {
    drawText("GIFBloom  /  开发手记", x: 78, y: 64, w: 530, h: 40,
             size: 24, bold: true, spacing: 0)
    roundRect(78, 116, 66, 7, radius: 4, fill: orange)
    drawText(number, x: 824, y: 67, w: 176, h: 34,
             size: 20, color: gray, align: .right, spacing: 0)
}

private func cover(_ bg: NSImage, _ icon: NSImage, _ output: URL) throws {
    try withPage(output) {
        background(bg)
        masthead("第一次记录")
        roundRect(422, 185, 236, 236, radius: 54,
                  fill: NSColor.white.withAlphaComponent(0.72),
                  stroke: NSColor.white.withAlphaComponent(0.9), width: 2)
        place(icon, x: 440, y: 203, w: 200, h: 200, radius: 42)
        drawText("我在做一个 iOS App", x: 92, y: 465, w: 896, h: 48,
                 size: 29, color: blue, bold: true, align: .center, spacing: 0)
        drawText("把视频里的瞬间，\n做成会动的透明贴纸", x: 82, y: 536, w: 916, h: 210,
                 size: 66, bold: true, align: .center, spacing: 11)
        drawText("GIFBloom · 独立开发中的动态表情工具", x: 105, y: 779, w: 870, h: 44,
                 size: 25, color: gray, align: .center, spacing: 0)
        drawPill("人物剪影", x: 116, y: 860, w: 190, fill: lightBlue, color: blue)
        drawPill("时间轴编辑", x: 326, y: 860, w: 210, fill: lightOrange, color: orange)
        drawPill("透明 GIF", x: 556, y: 860, w: 190, fill: lightBlue, color: blue)
        addStickerSpace()
        drawText("女儿出生以后，我想把那些小瞬间做成表情包。",
                 x: 110, y: 1010, w: 560, h: 112, size: 27, color: dark, spacing: 11)
        drawLine(110, 1178, 650, 1178, color: NSColor(calibratedWhite: 0.68, alpha: 0.48), width: 2)
        drawText("向左滑，听我讲讲这个 App 是怎么来的  →",
                 x: 110, y: 1210, w: 570, h: 64, size: 21, color: orange, bold: true, spacing: 4)
    }
}

private func origin(_ bg: NSImage, _ output: URL) throws {
    try withPage(output) {
        background(bg)
        masthead("02 / 04")
        drawPill("做这个 App 的起因", x: 78, y: 178, w: 270, fill: lightOrange, color: orange)
        drawText("女儿出生后，\n我手机里多了好多视频", x: 78, y: 278, w: 610, h: 174,
                 size: 53, bold: true, spacing: 8)
        drawText("她的小表情、小动作，\n我都想好好留着。\n\n有时候也想发给家人朋友看，\n但又不太想直接把照片和视频发出去。",
                 x: 88, y: 484, w: 575, h: 328, size: 28, color: dark, spacing: 10)
        roundRect(88, 838, 555, 3, radius: 2, fill: NSColor(calibratedWhite: 0.68, alpha: 0.5))
        drawText("我就想：能不能把这些瞬间，\n做成表情包来分享？",
                 x: 88, y: 873, w: 570, h: 105, size: 27, color: blue, bold: true, spacing: 8)
        addStickerSpace()
        drawText("一个很小的念头，后来变成了一个 App。",
                 x: 90, y: 1300, w: 900, h: 34, size: 20, color: gray, align: .center, spacing: 0)
    }
}

private func howItStarted(_ bg: NSImage, _ output: URL) throws {
    try withPage(output) {
        background(bg)
        masthead("03 / 04")
        drawPill("后来我决定自己做", x: 78, y: 178, w: 286, fill: lightBlue, color: blue)
        drawText("试了几个 GIF 软件，\n还是觉得不太顺手", x: 78, y: 278, w: 640, h: 176,
                 size: 53, bold: true, spacing: 8)
        drawText("用起来总觉得差点意思。\n后来一想：那我自己做一个吧。",
                 x: 88, y: 494, w: 590, h: 106, size: 28, color: dark, spacing: 10)
        drawText("现在大概是这么用：", x: 90, y: 677, w: 550, h: 34,
                 size: 22, color: gray, bold: true, spacing: 0)
        let boxes: [(CGFloat, String, NSColor, NSColor)] = [
            (90, "视频 /\nLive Photo", lightBlue, blue),
            (306, "抠出\n人物剪影", lightOrange, orange),
            (522, "导出透明\nGIF 表情", lightBlue, blue)
        ]
        for (x, label, fill, accent) in boxes {
            roundRect(x, 740, 180, 142, radius: 23,
                      fill: fill.withAlphaComponent(0.92), stroke: NSColor.white, width: 2)
            drawText(label, x: x + 12, y: 774, w: 156, h: 76,
                     size: 23, color: accent, bold: true, align: .center, spacing: 5)
        }
        for x in [CGFloat(278), CGFloat(494)] {
            drawLine(x, 811, x + 19, 811, color: gray.withAlphaComponent(0.65), width: 3)
            drawLine(x + 11, 803, x + 19, 811, color: gray.withAlphaComponent(0.65), width: 3)
            drawLine(x + 11, 819, x + 19, 811, color: gray.withAlphaComponent(0.65), width: 3)
        }
        drawText("再加点文字、贴纸，调好时间，就能做成自己的表情包。",
                 x: 90, y: 907, w: 590, h: 65, size: 22, color: gray, spacing: 5)
        addStickerSpace()
        drawText("GIFBloom 还在慢慢长大。", x: 90, y: 1300, w: 900, h: 34,
                 size: 20, color: gray, align: .center, spacing: 0)
    }
}

private func latest(_ bg: NSImage, _ output: URL) throws {
    try withPage(output) {
        background(bg)
        masthead("04 / 04")
        drawPill("最近几天在忙什么", x: 78, y: 178, w: 286, fill: lightOrange, color: orange)
        drawText("最近在把\n小细节一点点磨顺", x: 78, y: 278, w: 620, h: 170,
                 size: 53, bold: true, spacing: 8)
        drawText("素材库可以批量整理了，\n剪影也能裁剪、旋转。\n\n透明 GIF 的导出规格和草稿保存，\n也重新理了一遍。",
                 x: 88, y: 488, w: 575, h: 300, size: 28, color: dark, spacing: 10)
        drawPill("素材整理", x: 88, y: 825, w: 160, fill: lightBlue, color: blue)
        drawPill("裁剪旋转", x: 265, y: 825, w: 170, fill: lightOrange, color: orange)
        drawPill("保存更稳", x: 452, y: 825, w: 160, fill: lightBlue, color: blue)
        drawText("第一次来发开发记录，之后隔几天更一次～\n\n你也会想把家里的小瞬间做成表情包吗？",
                 x: 88, y: 920, w: 575, h: 168, size: 24, color: blue, bold: true, spacing: 8)
        addStickerSpace()
        drawLine(90, 1290, 990, 1290, color: NSColor(calibratedWhite: 0.68, alpha: 0.48), width: 2)
        drawText("如果有想要的功能，也欢迎告诉我。",
                 x: 90, y: 1310, w: 900, h: 34, size: 20, color: gray, align: .center, spacing: 0)
    }
}

let args = CommandLine.arguments
guard args.count == 4 else {
    fputs("Usage: make_first_post.swift <background.png> <app-icon.png> <output-directory>\n", stderr)
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: args[3], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
guard let bg = NSImage(contentsOfFile: args[1]), let icon = NSImage(contentsOfFile: args[2]) else {
    fatalError("Could not load background or app icon")
}
try cover(bg, icon, outputDirectory.appendingPathComponent("01-cover.png"))
try origin(bg, outputDirectory.appendingPathComponent("02-why.png"))
try howItStarted(bg, outputDirectory.appendingPathComponent("03-how-it-started.png"))
try latest(bg, outputDirectory.appendingPathComponent("04-latest.png"))
print("Created four 1080x1440 cards in \(outputDirectory.path)")
