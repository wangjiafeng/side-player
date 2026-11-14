// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "side-player",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "side-player", targets: ["SidePlayer"])],
    targets: [
        .executableTarget(
            name: "SidePlayer",
            path: "Sources/SidePlayer",
            resources: [.copy("Resources")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
