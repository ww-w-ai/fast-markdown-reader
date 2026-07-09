// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FastMDReader",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FastMDReader",
            path: "Sources/FastMDReader"
        ),
        .testTarget(
            name: "FastMDReaderTests",
            dependencies: ["FastMDReader"],
            path: "Tests/FastMDReaderTests"
        ),
    ]
)
