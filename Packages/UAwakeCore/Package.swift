// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UAwakeCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "UAwakeCore", targets: ["UAwakeCore"])],
    targets: [
        .target(name: "UAwakeCore"),
        .testTarget(name: "UAwakeCoreTests", dependencies: ["UAwakeCore"]),
    ]
)
