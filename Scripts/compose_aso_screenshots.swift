import AppKit
import Foundation

private struct ScreenshotAttachment: Decodable {
    let exportedFileName: String
    let suggestedHumanReadableName: String

    enum CodingKeys: String, CodingKey {
        case exportedFileName = "exportedFileName"
        case suggestedHumanReadableName = "suggestedHumanReadableName"
    }
}

private struct ScreenshotGroup: Decodable {
    let attachments: [ScreenshotAttachment]
}

private struct StoreLocale {
    let storeCode: String
    let bundleLocale: String
}

private let locales = [
    StoreLocale(storeCode: "ar-SA", bundleLocale: "ar"),
    StoreLocale(storeCode: "de-DE", bundleLocale: "de"),
    StoreLocale(storeCode: "en-US", bundleLocale: "en"),
    StoreLocale(storeCode: "es-ES", bundleLocale: "es"),
    StoreLocale(storeCode: "fr-FR", bundleLocale: "fr"),
    StoreLocale(storeCode: "hi", bundleLocale: "hi"),
    StoreLocale(storeCode: "id", bundleLocale: "id"),
    StoreLocale(storeCode: "it", bundleLocale: "it"),
    StoreLocale(storeCode: "ja", bundleLocale: "ja"),
    StoreLocale(storeCode: "ko", bundleLocale: "ko"),
    StoreLocale(storeCode: "pt-BR", bundleLocale: "pt-BR"),
    StoreLocale(storeCode: "ru", bundleLocale: "ru"),
    StoreLocale(storeCode: "th", bundleLocale: "th"),
    StoreLocale(storeCode: "tr", bundleLocale: "tr"),
    StoreLocale(storeCode: "vi", bundleLocale: "vi"),
    StoreLocale(storeCode: "zh-Hans", bundleLocale: "zh-Hans"),
    StoreLocale(storeCode: "zh-Hant", bundleLocale: "zh-Hant")
]

private struct ScreenshotSlot {
    let captureSuffix: String
    let outputName: String
    let titleKey: String
    let subtitleKey: String?
}

private let slots = [
    ScreenshotSlot(captureSuffix: "01-editor", outputName: "01-editor", titleKey: "时间轴", subtitleKey: nil),
    ScreenshotSlot(captureSuffix: "04-sticker", outputName: "02-stickers", titleKey: "贴纸", subtitleKey: "轻点添加，长按预览"),
    ScreenshotSlot(captureSuffix: "06-export", outputName: "03-export", titleKey: "导出", subtitleKey: nil),
    ScreenshotSlot(captureSuffix: "02-canvas", outputName: "04-canvas", titleKey: "画布", subtitleKey: "调整比例、画布背景和画面外缘"),
    ScreenshotSlot(captureSuffix: "03-text", outputName: "05-text", titleKey: "文字", subtitleKey: "输入内容并调整文字的视觉样式"),
    ScreenshotSlot(captureSuffix: "05-crop", outputName: "06-crop", titleKey: "裁剪", subtitleKey: nil)
]

private let canvasWidth = 1320
private let canvasHeight = 2868

private func topRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: x, y: CGFloat(canvasHeight) - y - height, width: width, height: height)
}

private func fontFitting(_ text: String, weight: NSFont.Weight, maxWidth: CGFloat, startSize: CGFloat) -> NSFont {
    var size = startSize
    while size > 48 {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= maxWidth { return font }
        size -= 2
    }
    return NSFont.systemFont(ofSize: size, weight: weight)
}

private func drawText(
    _ text: String,
    rect: NSRect,
    font: NSFont,
    color: NSColor,
    direction: NSWritingDirection,
    alignment: NSTextAlignment = .center
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.baseWritingDirection = direction
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    (text as NSString).draw(in: rect, withAttributes: attributes)
}

private func dictionary(for locale: StoreLocale, from root: URL) throws -> [String: String] {
    let path = root.appendingPathComponent("\(locale.bundleLocale).lproj/Localizable.strings").path
    guard let values = NSDictionary(contentsOfFile: path) as? [String: String] else {
        throw NSError(domain: "ScreenshotComposer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to read \(path)"])
    }
    return values
}

private func compose(
    screenshot: NSImage,
    locale: StoreLocale,
    slot: ScreenshotSlot,
    strings: [String: String],
    outputURL: URL
) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvasWidth,
        pixelsHigh: canvasHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "ScreenshotComposer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create the screenshot canvas"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high

    let pageRect = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.93, green: 0.97, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.84, green: 0.92, blue: 0.98, alpha: 1)
    ])?.draw(in: pageRect, angle: 90)

    let direction: NSWritingDirection = locale.bundleLocale == "ar" ? .rightToLeft : .leftToRight
    let brandFont = NSFont.systemFont(ofSize: 48, weight: .bold)
    drawText(
        "GIFBloom",
        rect: topRect(x: 70, y: 48, width: 1180, height: 70),
        font: brandFont,
        color: NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.27, alpha: 1),
        direction: .leftToRight
    )

    let rawTitle = strings[slot.titleKey] ?? slot.titleKey
    let title = rawTitle.rangeOfCharacter(from: .letters) != nil && locale.bundleLocale != "ar"
        ? rawTitle.capitalized
        : rawTitle
    let titleFont = fontFitting(title, weight: .heavy, maxWidth: 1200, startSize: 104)
    drawText(
        title,
        rect: topRect(x: 52, y: 127, width: 1216, height: 134),
        font: titleFont,
        color: NSColor(calibratedRed: 0.89, green: 0.31, blue: 0.16, alpha: 1),
        direction: direction
    )

    if let subtitleKey = slot.subtitleKey, let subtitle = strings[subtitleKey] {
        drawText(
            subtitle,
            rect: topRect(x: 86, y: 259, width: 1148, height: 100),
            font: NSFont.systemFont(ofSize: 34, weight: .medium),
            color: NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.27, alpha: 1),
            direction: direction
        )
    }

    let frameRect = topRect(x: 88, y: 384, width: 1144, height: 2458)
    let framePath = NSBezierPath(roundedRect: frameRect, xRadius: 86, yRadius: 86)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.10, alpha: 0.20)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
    framePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let imageRect = topRect(x: 104, y: 400, width: 1112, height: 2426)
    let imageClip = NSBezierPath(roundedRect: imageRect, xRadius: 72, yRadius: 72)
    NSGraphicsContext.saveGraphicsState()
    imageClip.addClip()
    screenshot.draw(
        in: imageRect,
        from: NSRect(origin: .zero, size: screenshot.size),
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ScreenshotComposer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to encode \(outputURL.lastPathComponent)"])
    }
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: outputURL, options: .atomic)
}

func run() throws {
    guard CommandLine.arguments.count == 5 else {
        fputs("Usage: swift compose_aso_screenshots.swift <manifest.json> <attachments-dir> <localization-root> <output-root>\n", stderr)
        exit(2)
    }
    let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let attachmentRoot = URL(fileURLWithPath: CommandLine.arguments[2])
    let localizationRoot = URL(fileURLWithPath: CommandLine.arguments[3])
    let outputRoot = URL(fileURLWithPath: CommandLine.arguments[4])
    let manifestData = try Data(contentsOf: manifestURL)
    let groups = try JSONDecoder().decode([ScreenshotGroup].self, from: manifestData)
    let attachments = groups.flatMap(\.attachments)

    for locale in locales {
        let strings = try dictionary(for: locale, from: localizationRoot)
        for slot in slots {
            let expectedName = "store-\(locale.storeCode)-\(slot.captureSuffix)"
            guard let attachment = attachments.first(where: { $0.suggestedHumanReadableName.hasPrefix(expectedName) }) else {
                throw NSError(domain: "ScreenshotComposer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing capture \(expectedName)"])
            }
            let imageURL = attachmentRoot.appendingPathComponent(attachment.exportedFileName)
            guard let screenshot = NSImage(contentsOf: imageURL) else {
                throw NSError(domain: "ScreenshotComposer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unable to load \(imageURL.path)"])
            }
            let outputURL = outputRoot.appendingPathComponent(locale.storeCode).appendingPathComponent("\(slot.outputName).png")
            try compose(screenshot: screenshot, locale: locale, slot: slot, strings: strings, outputURL: outputURL)
            print("\(locale.storeCode)/\(slot.outputName).png")
        }
    }
}

do {
    try run()
} catch {
    fputs("Screenshot composition failed: \(error)\n", stderr)
    exit(1)
}
