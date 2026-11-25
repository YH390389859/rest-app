// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rest",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Rest", targets: ["Rest"])
    ],
    targets: [
        .executableTarget(
            name: "Rest",
            path: "Sources/Rest"
        )
    ]
)
