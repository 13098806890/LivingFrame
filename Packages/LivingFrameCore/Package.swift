// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LivingFrameCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LivingFrameCore", targets: ["LivingFrameCore"])
    ],
    targets: [
        .target(
            name: "LivingFrameCore",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LivingFrameCoreTests",
            dependencies: ["LivingFrameCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
