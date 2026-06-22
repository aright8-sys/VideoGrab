// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoGrab",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "VideoGrab",
            path: "Sources/VideoGrab"
        )
    ]
)
