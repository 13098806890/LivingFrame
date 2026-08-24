import CoreGraphics

struct PaperTextureStyle: Sendable {
    var seed: UInt64
    var pointsPerArea: CGFloat
    var minimumPointCount: Int
    var maximumPointCount: Int
    var opacityMultiplier: CGFloat

    static let cotton = PaperTextureStyle(
        seed: 0xC0FFEE_2A4B_19D3,
        pointsPerArea: 1 / 1_400,
        minimumPointCount: 700,
        maximumPointCount: 4_200,
        opacityMultiplier: 1
    )

    static let canvas = PaperTextureStyle(
        seed: 0xC0FFEE_2A4B_19D3,
        pointsPerArea: 1 / 1_050,
        minimumPointCount: 1_000,
        maximumPointCount: 5_500,
        opacityMultiplier: 1.55
    )

    static let foldedBack = PaperTextureStyle(
        seed: 0xF01D_EDBA_CAC7,
        pointsPerArea: 1 / 520,
        minimumPointCount: 120,
        maximumPointCount: 650,
        opacityMultiplier: 1.35
    )
}

/// 可复用的固定种子纸张颗粒绘制器。
enum PaperTextureRenderer {
    static func drawGrain(
        in context: CGContext,
        bounds: CGRect,
        excluding cutoutPath: CGPath? = nil,
        style: PaperTextureStyle = .cotton
    ) {
        context.saveGState()
        context.addRect(bounds)
        if let cutoutPath {
            context.addPath(cutoutPath)
            context.clip(using: .evenOdd)
        } else {
            context.clip()
        }

        var random = SeededPaperRandomNumberGenerator(state: style.seed)
        let requestedCount = Int(bounds.width * bounds.height * style.pointsPerArea)
        let count = min(max(requestedCount, style.minimumPointCount), style.maximumPointCount)

        // 大尺度纸浆明暗，让白纸不再是一块纯色塑料。
        let cloudCount = min(max(count / 28, 32), 150)
        for _ in 0..<cloudCount {
            let x = bounds.minX + random.nextUnit() * bounds.width
            let y = bounds.minY + random.nextUnit() * bounds.height
            let radius = 5 + random.nextUnit() * 20
            let shade = 0.58 + random.nextUnit() * 0.30
            context.setFillColor(CGColor(gray: shade, alpha: min((0.018 + random.nextUnit() * 0.035) * style.opacityMultiplier, 1)))
            context.fillEllipse(in: CGRect(
                x: x - radius,
                y: y - radius * 0.45,
                width: radius * 2,
                height: radius * 0.9
            ))
        }

        for _ in 0..<count {
            let x = bounds.minX + random.nextUnit() * bounds.width
            let y = bounds.minY + random.nextUnit() * bounds.height
            let radius = 0.35 + random.nextUnit() * 1.25
            let shade = 0.60 + random.nextUnit() * 0.28
            let alpha = min((0.052 + random.nextUnit() * 0.115) * style.opacityMultiplier, 1)
            context.setFillColor(CGColor(gray: shade, alpha: alpha))
            context.fillEllipse(in: CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }

        // 稀疏的短纤维线只在纸面内出现，缩小后仍能留下自然的方向纹理。
        let fibreCount = min(max(count / 11, 70), 380)
        context.setLineCap(.round)
        for _ in 0..<fibreCount {
            let x = bounds.minX + random.nextUnit() * bounds.width
            let y = bounds.minY + random.nextUnit() * bounds.height
            let length = 5 + random.nextUnit() * 20
            let angle = (random.nextUnit() - 0.5) * 0.55
            context.setStrokeColor(CGColor(
                gray: 0.52 + random.nextUnit() * 0.32,
                alpha: min((0.055 + random.nextUnit() * 0.115) * style.opacityMultiplier, 1)
            ))
            context.setLineWidth(0.45 + random.nextUnit() * 0.85)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(
                x: x + cos(angle) * length,
                y: y + sin(angle) * length
            ))
            context.strokePath()
        }
        context.restoreGState()
    }
}

private struct SeededPaperRandomNumberGenerator {
    var state: UInt64

    mutating func nextUnit() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat((state >> 40) & 0x00FF_FFFF) / CGFloat(0x00FF_FFFF)
    }
}
