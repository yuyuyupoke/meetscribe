// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetScribe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MeetScribe", targets: ["MeetScribe"])
    ],
    targets: [
        .executableTarget(
            name: "MeetScribe",
            path: "Sources/MeetScribe"
        )
    ]
)
