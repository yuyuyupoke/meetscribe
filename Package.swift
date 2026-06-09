// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawdListen",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClawdListen", targets: ["ClawdListen"])
    ],
    targets: [
        .executableTarget(
            name: "ClawdListen",
            path: "Sources/ClawdListen"
        )
    ]
)
