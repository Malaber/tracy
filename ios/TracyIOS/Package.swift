// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TracyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TracyCore", targets: ["TracyCore"])],
    targets: [
        .target(name: "TracyCore"),
        .testTarget(name: "TracyCoreTests", dependencies: ["TracyCore"]),
    ]
)
