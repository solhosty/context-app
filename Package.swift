// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Context",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ContextApp", targets: ["ContextApp"])
    ],
    targets: [
        .executableTarget(name: "ContextApp"),
        .testTarget(name: "ContextAppTests", dependencies: ["ContextApp"])
    ]
)
