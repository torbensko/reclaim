// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reclaim",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Reclaim", targets: ["Reclaim"]),
        .executable(name: "ReclaimWorker", targets: ["ReclaimWorker"]),
        .library(name: "ReclaimCore", targets: ["ReclaimCore"])
    ],
    targets: [
        .target(name: "ReclaimCore"),
        .executableTarget(name: "Reclaim", dependencies: ["ReclaimCore"]),
        .executableTarget(name: "ReclaimWorker", dependencies: ["ReclaimCore"]),
        .testTarget(name: "ReclaimCoreTests", dependencies: ["ReclaimCore"])
    ]
)
