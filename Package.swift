// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unseen",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Unseen", targets: ["Unseen"])
    ],
    targets: [
        .executableTarget(
            name: "Unseen",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
