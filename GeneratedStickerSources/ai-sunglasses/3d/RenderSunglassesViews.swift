import AppKit
import Foundation
import ImageIO
import SceneKit

enum RenderSunglassesViews {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let scene = makeScene()
        let modelURL = output.appendingPathComponent("amethyst-sunglasses.scn")
        scene.write(to: modelURL, options: nil, delegate: nil, progressHandler: nil)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        let views: [(String, CGFloat)] = [
            ("sunglasses-3d-front.png", 0),
            ("sunglasses-3d-three-quarter.png", 0.70),
            ("sunglasses-3d-profile.png", 1.30)
        ]
        for (name, yaw) in views {
            guard let viewRoot = scene.rootNode.childNode(withName: "viewRoot", recursively: true) else { fatalError("Missing model root") }
            viewRoot.eulerAngles.y = yaw
            let snapshot = renderer.snapshot(
                atTime: 0,
                with: CGSize(width: 1024, height: 1024),
                antialiasingMode: .multisampling4X
            )
            for x: Float in [-0.42, 0.42] {
                let worldPoint = viewRoot.convertPosition(SCNVector3(x, 0, 0.10), to: nil)
                let projected = renderer.projectPoint(worldPoint)
                print("\(name) eye anchor x=\(projected.x / 1024), y=\(1 - projected.y / 1024)")
            }
            var proposedRect = CGRect(origin: .zero, size: snapshot.size)
            guard let image = snapshot.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                throw NSError(domain: "RenderSunglassesViews", code: 1, userInfo: [NSLocalizedDescriptionKey: "SceneKit could not snapshot \(name)"])
            }
            let url = output.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw NSError(domain: "RenderSunglassesViews", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create \(url.path)"])
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "RenderSunglassesViews", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.path)"])
            }
            print("Rendered \(url.path)")
        }
    }

    private static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1.2
        camera.zNear = 0.1
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.name = "camera"
        cameraNode.position = SCNVector3(0, 0, 8)
        scene.rootNode.addChildNode(cameraNode)

        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(calibratedWhite: 0.55, alpha: 1)
        ambient.intensity = 430
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        addLight(to: scene, position: SCNVector3(-3.5, 4.5, 5), color: NSColor(calibratedRed: 0.72, green: 0.82, blue: 1, alpha: 1), intensity: 1000)
        addLight(to: scene, position: SCNVector3(4, 1, 3), color: NSColor(calibratedRed: 0.80, green: 0.43, blue: 1, alpha: 1), intensity: 650)
        addLight(to: scene, position: SCNVector3(0, -3, -3), color: NSColor(calibratedRed: 0.28, green: 0.70, blue: 1, alpha: 1), intensity: 500)

        let viewRoot = SCNNode()
        viewRoot.name = "viewRoot"
        scene.rootNode.addChildNode(viewRoot)
        addGlasses(to: viewRoot)
        return scene
    }

    private static func addLight(to scene: SCNScene, position: SCNVector3, color: NSColor, intensity: CGFloat) {
        let node = SCNNode()
        let light = SCNLight()
        light.type = .directional
        light.color = color
        light.intensity = intensity
        node.light = light
        node.position = position
        node.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(node)
    }

    private static func addGlasses(to root: SCNNode) {
        let frameMaterial = material(color: NSColor(calibratedRed: 0.39, green: 0.19, blue: 0.82, alpha: 1), metallic: 0.72, roughness: 0.2)
        let outlineMaterial = material(color: NSColor.white, metallic: 0, roughness: 0.65)
        let bridgeMaterial = material(color: NSColor(calibratedRed: 0.55, green: 0.32, blue: 0.94, alpha: 1), metallic: 0.62, roughness: 0.22)

        // A thin white rim gives the rendered model the same cut-out sticker edge
        // as the 2D comparison asset while all of the underlying shapes stay 3D.
        for x: Float in [-0.42, 0.42] {
            let backing = roundedFrame(width: 0.99, height: 0.67, innerWidth: 0.78, innerHeight: 0.45, corner: 0.18, material: outlineMaterial)
            backing.position = SCNVector3(x, 0, -0.075)
            backing.scale = SCNVector3(1.10, 1.09, 1)
            root.addChildNode(backing)
        }
        let backingBridge = bar(from: SCNVector3(-0.13, 0.02, -0.075), to: SCNVector3(0.13, 0.02, -0.075), radius: 0.055, material: outlineMaterial)
        root.addChildNode(backingBridge)

        for x: Float in [-0.42, 0.42] {
            let lens = SCNBox(width: 0.75, height: 0.43, length: 0.045, chamferRadius: 0.085)
            let lensMaterial = SCNMaterial()
            lensMaterial.lightingModel = .physicallyBased
            lensMaterial.diffuse.contents = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.29, alpha: 1)
            lensMaterial.metalness.contents = 0.66
            lensMaterial.roughness.contents = 0.16
            lensMaterial.transparency = 0.88
            lensMaterial.isDoubleSided = true
            lens.materials = [lensMaterial]
            let lensNode = SCNNode(geometry: lens)
            lensNode.position = SCNVector3(x, 0, 0.045)
            root.addChildNode(lensNode)

            let frame = roundedFrame(width: 0.99, height: 0.67, innerWidth: 0.78, innerHeight: 0.45, corner: 0.18, material: frameMaterial)
            frame.position = SCNVector3(x, 0, 0.10)
            root.addChildNode(frame)

            let hinge = SCNSphere(radius: 0.075)
            hinge.firstMaterial = bridgeMaterial
            let hingeNode = SCNNode(geometry: hinge)
            hingeNode.position = SCNVector3(x * 2.05, 0.01, 0.04)
            root.addChildNode(hingeNode)

            // Temple arms run back along negative z and become visible naturally
            // as the model turns toward its side views.
            let temple = SCNBox(width: 0.105, height: 0.11, length: 1.36, chamferRadius: 0.045)
            temple.materials = [frameMaterial]
            let templeNode = SCNNode(geometry: temple)
            templeNode.position = SCNVector3(x * 2.14, 0.015, -0.76)
            templeNode.eulerAngles.y = x < 0 ? -0.10 : 0.10
            root.addChildNode(templeNode)
        }

        root.addChildNode(bar(from: SCNVector3(-0.15, 0.025, 0.10), to: SCNVector3(0.15, 0.025, 0.10), radius: 0.07, material: bridgeMaterial))
        for x: Float in [-0.14, 0.14] {
            let nosePad = SCNBox(width: 0.12, height: 0.06, length: 0.10, chamferRadius: 0.025)
            nosePad.firstMaterial = material(color: NSColor(calibratedRed: 0.64, green: 0.55, blue: 0.88, alpha: 1), metallic: 0.25, roughness: 0.35)
            let node = SCNNode(geometry: nosePad)
            node.position = SCNVector3(x, -0.21, 0.15)
            root.addChildNode(node)
        }
    }

    private static func roundedFrame(width: CGFloat, height: CGFloat, innerWidth: CGFloat, innerHeight: CGFloat, corner: CGFloat, material: SCNMaterial) -> SCNNode {
        let geometry = ringGeometry(width: width, height: height, innerWidth: innerWidth, innerHeight: innerHeight, corner: corner)
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func ringGeometry(width: CGFloat, height: CGFloat, innerWidth: CGFloat, innerHeight: CGFloat, corner: CGFloat) -> SCNGeometry {
        let outer = roundedRect(width: width, height: height, radius: corner, z: 0.06)
        let inner = roundedRect(width: innerWidth, height: innerHeight, radius: corner * 0.68, z: 0.06)
        let count = outer.count
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(count * 4)
        vertices.append(contentsOf: outer)
        vertices.append(contentsOf: inner)
        vertices.append(contentsOf: outer.map { SCNVector3($0.x, $0.y, -0.06) })
        vertices.append(contentsOf: inner.map { SCNVector3($0.x, $0.y, -0.06) })

        var indices: [Int32] = []
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            indices.append(contentsOf: [Int32(a), Int32(b), Int32(c), Int32(a), Int32(c), Int32(d)])
        }
        for i in 0..<count {
            let next = (i + 1) % count
            quad(i, next, count + next, count + i)
            quad(2 * count + i, 3 * count + i, 3 * count + next, 2 * count + next)
            quad(i, 2 * count + i, 2 * count + next, next)
            quad(count + i, count + next, 3 * count + next, 3 * count + i)
        }
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.isDoubleSided = true
        return geometry
    }

    private static func roundedRect(width: CGFloat, height: CGFloat, radius: CGFloat, z: Float) -> [SCNVector3] {
        let halfWidth = width / 2
        let halfHeight = height / 2
        let r = min(radius, min(halfWidth, halfHeight))
        let corners: [(CGFloat, CGFloat, CGFloat)] = [
            (halfWidth - r, halfHeight - r, 0),
            (-halfWidth + r, halfHeight - r, 90),
            (-halfWidth + r, -halfHeight + r, 180),
            (halfWidth - r, -halfHeight + r, 270)
        ]
        return corners.flatMap { cx, cy, start in
            (0..<12).map { step in
                let angle = (start + CGFloat(step) * 90 / 12) * .pi / 180
                return SCNVector3(Float(cx + cos(angle) * r), Float(cy + sin(angle) * r), z)
            }
        }
    }

    private static func bar(from start: SCNVector3, to end: SCNVector3, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let length = hypot(hypot(CGFloat(end.x - start.x), CGFloat(end.y - start.y)), CGFloat(end.z - start.z))
        let geometry = SCNCylinder(radius: radius, height: length)
        geometry.radialSegmentCount = 16
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3((start.x + end.x) / 2, (start.y + end.y) / 2, (start.z + end.z) / 2)
        let direction = SCNVector3(end.x - start.x, end.y - start.y, end.z - start.z)
        node.eulerAngles = SCNVector3(atan2(-direction.z, direction.y), 0, atan2(direction.x, direction.y))
        return node
    }

    private static func material(color: NSColor, metallic: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = metallic
        material.roughness.contents = roughness
        material.isDoubleSided = true
        return material
    }
}

try RenderSunglassesViews.main()
