// swift-tools-version: 6.0
// Local copy of the manifest from iCepa/Tor.framework. See VENDORED.md for why.
import PackageDescription

let package = Package(
    name: "TorFramework",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TorCore", targets: ["TorCore"]),
        .library(name: "CTorNoLzma", targets: ["CTorNoLzma"]),
    ],
    targets: [
        .target(name: "TorCore", publicHeadersPath: "include"),
        .binaryTarget(
            name: "tor-nolzma",
            url: "https://github.com/iCepa/Tor.framework/releases/download/409.15.2/tor-nolzma.xcframework.zip",
            checksum: "0c3921c9fc58631428904f77d9c4afd49fa4c77ad608abf547bf7c409bb33b70"
        ),
        .target(
            name: "CTorNoLzma",
            dependencies: ["TorCore", "tor-nolzma"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
    ]
)
