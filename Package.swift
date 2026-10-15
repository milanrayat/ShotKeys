// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShotKeys",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ShotKeys",
            path: "Sources/ShotKeys"
        )
    ]
)
