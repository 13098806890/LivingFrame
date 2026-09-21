// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LivingFrameCore",
    platforms: [
        .iOS("26.0"),
        .macOS("14.0")
    ],
    products: [
        .library(name: "LivingFrameCore", targets: ["LivingFrameCore"])
    ],
    targets: [
        .target(
            name: "LivingFrameCore",
            resources: [
                .process("Resources"),
                // Keep the three Core ML package trees intact. They live
                // outside the normal resource directory so SwiftPM does not
                // flatten duplicate model.mlmodel/weight.bin names.
                .copy("SAM2Models")
            ]
        ),
        .testTarget(
            name: "LivingFrameCoreTests",
            dependencies: ["LivingFrameCore"]
        )
    ]
)
