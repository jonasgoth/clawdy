// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clawdy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clawdy",
            path: "Sources/Clawdy",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SpriteKit")]
        )
    ]
)
