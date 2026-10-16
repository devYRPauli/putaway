// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "putaway",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "PutawayCore"),
        .executableTarget(name: "putaway", dependencies: ["PutawayCore"]),
        .testTarget(name: "PutawayCoreTests", dependencies: ["PutawayCore"]),
    ]
)
