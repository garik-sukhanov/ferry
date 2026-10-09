// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ferry",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CCurl",
            path: "Sources/CCurl",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("curl")]
        ),
        .executableTarget(
            name: "Ferry",
            dependencies: ["CCurl"],
            path: "Sources/Ferry",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FerryTests",
            dependencies: ["Ferry"],
            path: "Tests/FerryTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
