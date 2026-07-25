// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shortking",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Shortking", targets: ["ShortkingApp"]),
        .executable(name: "shortking-probe", targets: ["ShortkingProbe"]),
        .library(name: "ShortkingKit", targets: ["ShortkingKit"]),
    ],
    targets: [
        .target(
            name: "ShortkingKit",
            path: "Sources/ShortkingKit"
        ),
        .executableTarget(
            name: "ShortkingApp",
            dependencies: ["ShortkingKit"],
            path: "Sources/ShortkingApp"
        ),
        .executableTarget(
            name: "ShortkingProbe",
            dependencies: ["ShortkingKit"],
            path: "Sources/ShortkingProbe"
        ),
        .testTarget(
            name: "ShortkingKitTests",
            dependencies: ["ShortkingKit"],
            path: "Tests/ShortkingKitTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
