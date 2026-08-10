// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LivingFrameCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LivingFrameCore", targets: ["LivingFrameCore"])
    ],
    targets: [
        .target(
            name: "LivingFrameCore"
        )
    ]
)
