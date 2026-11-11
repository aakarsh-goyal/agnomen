// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Agnomen",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Agnomen",
            path: "Sources/Agnomen",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
