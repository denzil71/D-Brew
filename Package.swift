// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DBrew",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DBrew",
            path: "Sources/DBrew"
        )
    ]
)
