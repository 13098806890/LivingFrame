#if DEBUG
import LivingFrameCore
import UIKit

/// 为 Simulator 功能巡检准备确定性工程。仅在显式传入
/// `-UIAuditSeedProject` 时执行，不影响正常启动和 Release 构建。
@MainActor
enum UIAuditFixtureSeeder {
    private static var didSeed = false

    static func seedIfRequested(into appState: AppState) async {
        guard !didSeed,
              ProcessInfo.processInfo.arguments.contains("-UIAuditSeedProject") else { return }
        didSeed = true

        appState.createComposition(aspect: .square1x1)

        if let mediaID = await appState.importBackgroundMedia(
            data: makeFixtureImage(),
            preferredFileExtension: "png"
        ) {
            await appState.reloadBackgroundMediaAndWait()
            let elementIDs = appState.addBackgroundElements(mediaIDs: [mediaID])
            if let elementID = elementIDs.first {
                // 拼接素材新建后与真实用户流程一样处于“待分配”状态；
                // 单图巡检将它明确放入完整画布的第一个区域。
                appState.setBackgroundPartition(elementID, 0)
            }
        }

        // 同时准备动态内容与可编辑文字，使播放、文字、保存和导出流程
        // 不依赖照片权限或外部测试资源。
        appState.addSticker("sticker-firework")
        if let textID = appState.addTextElement() {
            appState.updateText(textID) {
                $0.text = "UI Audit"
                $0.fontSize = 112
                $0.colorHex = "FFFFFF"
                $0.fontName = "AvenirNext-Bold"
            }
        }

        if var composition = appState.composition {
            composition.name = "UI Audit Project"
            // 保留动态效果，同时把自动化导出的帧数控制在较小范围，
            // 让每次巡检都能稳定完成而不是把时间消耗在编码上。
            composition.duration = 3
            composition.fps = 15
            appState.composition = composition
        }
        appState.selectedTab = .editor
    }

    private static func makeFixtureImage() -> Data {
        let size = CGSize(width: 900, height: 900)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            let cg = context.cgContext
            let colors = [
                UIColor(red: 0.10, green: 0.23, blue: 0.36, alpha: 1).cgColor,
                UIColor(red: 0.22, green: 0.63, blue: 0.78, alpha: 1).cgColor,
                UIColor(red: 0.92, green: 0.46, blue: 0.64, alpha: 1).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0, 0.58, 1]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: locations
            )!
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )

            UIColor.white.withAlphaComponent(0.16).setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 90, y: 110, width: 720, height: 610),
                cornerRadius: 88
            ).fill()

            let circleColors: [UIColor] = [
                UIColor(red: 0.98, green: 0.82, blue: 0.31, alpha: 1),
                UIColor(red: 0.46, green: 0.88, blue: 0.72, alpha: 1),
                UIColor(red: 0.98, green: 0.55, blue: 0.48, alpha: 1)
            ]
            for (index, color) in circleColors.enumerated() {
                color.setFill()
                let x = 185 + CGFloat(index) * 210
                UIBezierPath(ovalIn: CGRect(x: x, y: 210, width: 110, height: 110)).fill()
            }

            let title = "LIVING\nFRAME" as NSString
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = -6
            title.draw(
                in: CGRect(x: 120, y: 390, width: 660, height: 230),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 92, weight: .black),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ]
            )
        }
    }
}
#endif
