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
        .target(
            name: "MeetScribeCore",
            path: "Sources/MeetScribe"
        ),
        .executableTarget(
            name: "MeetScribe",
            dependencies: ["MeetScribeCore"],
            path: "Sources/MeetScribeApp"
        ),
        .testTarget(
            name: "MeetScribeTests",
            dependencies: ["MeetScribeCore"],
            path: "Tests/MeetScribeTests"
        )
    ]
)
