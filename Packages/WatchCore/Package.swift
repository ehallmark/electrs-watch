// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WatchCore", targets: ["WatchCore"])],
    targets: [
        .target(name: "WatchCore"),
        .testTarget(name: "WatchCoreTests", dependencies: ["WatchCore"]),
    ]
)
