#if canImport(SceneKit)
import Foundation
import SceneKit

#if os(iOS) || os(tvOS)
import UIKit
private typealias StickerPlatformColor = UIColor
#elseif os(macOS)
import AppKit
private typealias StickerPlatformColor = NSColor
#endif

/// Renders the two AI accessories as actual SceneKit geometry. This is kept
/// separate from the authored multi-view PNG path so both approaches can be
/// compared in the sticker picker.
public enum Procedural3DStickerRenderer {
    private static let imageCache = NSCache<NSString, CGImage>()
    private static let lock = NSLock()

    public static func image(
        for decorationID: String,
        yaw: CGFloat?,
        pixelSize: Int = 768
    ) -> CGImage? {
        let safeYaw = (yaw ?? 0).isFinite ? (yaw ?? 0) : 0
        let quantizedYaw = (safeYaw * 24).rounded() / 24
        let key = "\(decorationID)|\(quantizedYaw)|\(pixelSize)" as NSString

        lock.lock()
        let cached = imageCache.object(forKey: key)
        lock.unlock()
        if let cached { return cached }

        guard decorationID == "sticker-ai-sunglasses-crayon-model-3d"
                || decorationID == "sticker-ai-cap-crayon-model-3d" else {
            return nil
        }

        let scene = SCNScene()
        scene.background.contents = StickerPlatformColor.clear
        scene.background.intensity = 0

        let model = SCNNode()
        setYaw(of: model, to: -quantizedYaw)
        if decorationID == "sticker-ai-sunglasses-crayon-model-3d" {
            buildSunglasses(in: model)
        } else {
            buildCap(in: model)
        }
        scene.rootNode.addChildNode(model)
        addLighting(to: scene)

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = decorationID == "sticker-ai-sunglasses-crayon-model-3d" ? 2.85 : 2.45
        camera.zNear = 0.01
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 6)
        scene.rootNode.addChildNode(cameraNode)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        renderer.isJitteringEnabled = true

        let size = CGSize(width: max(pixelSize, 64), height: max(pixelSize, 64))
        let rendered = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        let image: CGImage?
#if os(iOS) || os(tvOS)
        image = rendered.cgImage
#elseif os(macOS)
        var proposedRect = CGRect(origin: .zero, size: size)
        image = rendered.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
#else
        image = nil
#endif

        guard let image else { return nil }
        lock.lock()
        imageCache.setObject(image, forKey: key, cost: image.width * image.height * 4)
        lock.unlock()
        return image
    }

    private static func buildSunglasses(in root: SCNNode) {
        let teal = material(color: StickerPlatformColor(red: 0.03, green: 0.58, blue: 0.70, alpha: 1))
        let violet = material(color: StickerPlatformColor(red: 0.19, green: 0.06, blue: 0.38, alpha: 0.94))
        let yellow = material(color: StickerPlatformColor(red: 1.0, green: 0.73, blue: 0.08, alpha: 1))

        for x in [-0.56, 0.56] {
            let frame = SCNNode(geometry: box(width: 0.92, height: 0.60, depth: 0.16, chamfer: 0.12, material: teal))
            frame.position = SCNVector3(x, 0, 0)
            root.addChildNode(frame)

            let lens = SCNNode(geometry: box(width: 0.73, height: 0.42, depth: 0.18, chamfer: 0.10, material: violet))
            lens.position = SCNVector3(x, 0, 0.09)
            root.addChildNode(lens)

            let highlight = SCNNode(geometry: box(width: 0.06, height: 0.22, depth: 0.02, chamfer: 0.02, material: yellow))
            highlight.position = SCNVector3(x - (x < 0 ? -0.18 : 0.18), 0.12, 0.19)
            highlight.eulerAngles.z = -0.35
            root.addChildNode(highlight)
        }

        let bridge = SCNNode(geometry: box(width: 0.25, height: 0.10, depth: 0.14, chamfer: 0.04, material: teal))
        bridge.position = SCNVector3(0, 0, 0.02)
        root.addChildNode(bridge)

        for x in [-1.03, 1.03] {
            let arm = SCNNode(geometry: box(width: 0.86, height: 0.10, depth: 0.10, chamfer: 0.04, material: teal))
            arm.position = SCNVector3(x, 0.14, -0.01)
            arm.eulerAngles.z = x < 0 ? -0.12 : 0.12
            root.addChildNode(arm)
        }
    }

    private static func buildCap(in root: SCNNode) {
        let red = material(color: StickerPlatformColor(red: 0.88, green: 0.03, blue: 0.04, alpha: 1))
        let cream = material(color: StickerPlatformColor(red: 0.96, green: 0.82, blue: 0.50, alpha: 1))
        let blue = material(color: StickerPlatformColor(red: 0.04, green: 0.26, blue: 0.67, alpha: 1))

        let crown = SCNSphere(radius: 0.86)
        crown.segmentCount = 48
        crown.firstMaterial = red
        let crownNode = SCNNode(geometry: crown)
        crownNode.scale = SCNVector3(1.0, 0.76, 0.86)
        crownNode.position = SCNVector3(0, 0.16, 0)
        root.addChildNode(crownNode)

        let brim = SCNNode(geometry: box(width: 1.75, height: 0.12, depth: 0.72, chamfer: 0.16, material: cream))
        brim.position = SCNVector3(0, -0.38, 0.28)
        brim.eulerAngles.x = -0.18
        root.addChildNode(brim)

        let button = SCNSphere(radius: 0.13)
        button.segmentCount = 24
        button.firstMaterial = blue
        let buttonNode = SCNNode(geometry: button)
        buttonNode.position = SCNVector3(0, 0.84, 0)
        root.addChildNode(buttonNode)

        for x in [-0.43, 0, 0.43] {
            let stitch = SCNNode(geometry: box(width: 0.025, height: 0.025, depth: 0.56, chamfer: 0.01, material: blue))
            stitch.position = SCNVector3(x, -0.30, 0.36)
            setYaw(of: stitch, to: CGFloat(x * 0.32))
            root.addChildNode(stitch)
        }
    }

    private static func addLighting(to scene: SCNScene) {
        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = StickerPlatformColor(white: 0.68, alpha: 1)
        ambient.intensity = 520
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let keyNode = SCNNode()
        let key = SCNLight()
        key.type = .omni
        key.color = StickerPlatformColor(white: 1, alpha: 1)
        key.intensity = 1100
        keyNode.position = SCNVector3(-2, 3, 4)
        keyNode.light = key
        scene.rootNode.addChildNode(keyNode)
    }

    private static func setYaw(of node: SCNNode, to angle: CGFloat) {
#if os(iOS) || os(tvOS)
        node.eulerAngles.y = Float(angle)
#elseif os(macOS)
        node.eulerAngles.y = angle
#endif
    }

    private static func material(color: StickerPlatformColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.roughness.contents = 0.82
        material.metalness.contents = 0.02
        material.lightingModel = .physicallyBased
        return material
    }

    private static func box(
        width: CGFloat,
        height: CGFloat,
        depth: CGFloat,
        chamfer: CGFloat,
        material: SCNMaterial
    ) -> SCNBox {
        let geometry = SCNBox(
            width: width,
            height: height,
            length: depth,
            chamferRadius: chamfer
        )
        geometry.chamferSegmentCount = 6
        geometry.firstMaterial = material
        return geometry
    }
}
#endif
