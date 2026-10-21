// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Glimpse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Glimpse",
            path: "Sources/Glimpse"
        )
    ]
)
