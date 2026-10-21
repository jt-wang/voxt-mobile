// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxtMobileKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VoxtMobileKit", targets: ["VoxtMobileKit"]),
    ],
    targets: [
        .target(
            name: "VoxtMobileKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "VoxtMobileKitTests",
            dependencies: ["VoxtMobileKit"]
        ),
    ]
)
