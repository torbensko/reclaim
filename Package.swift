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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "ReclaimCore"),
        .executableTarget(name: "Reclaim", dependencies: ["ReclaimCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "ReclaimWorker", dependencies: ["ReclaimCore"]),
        .testTarget(name: "ReclaimCoreTests", dependencies: ["ReclaimCore"]),
        .testTarget(name: "ReclaimAppTests", dependencies: ["Reclaim", "ReclaimCore"])
    ]
)
