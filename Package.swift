// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dice",
            path: "Sources/Dice"
        )
    ],
    swiftLanguageModes: [.v5]
)
