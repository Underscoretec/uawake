// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UAwakeSystem",
    platforms: [.macOS(.v14)],
    products: [.library(name: "UAwakeSystem", targets: ["UAwakeSystem"])],
    dependencies: [.package(path: "../UAwakeCore")],
    targets: [.target(name: "UAwakeSystem", dependencies: ["UAwakeCore"])]
)
