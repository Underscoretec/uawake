// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UAwakeIPC",
    platforms: [.macOS(.v14)],
    products: [.library(name: "UAwakeIPC", targets: ["UAwakeIPC"])],
    dependencies: [.package(path: "../UAwakeCore")],
    targets: [
        .target(name: "UAwakeIPC", dependencies: ["UAwakeCore"]),
        .testTarget(name: "UAwakeIPCTests", dependencies: ["UAwakeIPC"]),
    ]
)
