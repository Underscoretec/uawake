// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UAwakeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UAwakeCore", targets: ["UAwakeCore"]),
        // Fakes shared by every package's tests. Never linked into the app.
        .library(name: "UAwakeCoreTesting", targets: ["UAwakeCoreTesting"]),
    ],
    targets: [
        .target(name: "UAwakeCore"),
        .target(name: "UAwakeCoreTesting", dependencies: ["UAwakeCore"]),
        .testTarget(name: "UAwakeCoreTests", dependencies: ["UAwakeCore", "UAwakeCoreTesting"]),
    ]
)
