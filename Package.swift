// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Audium",
    platforms: [.macOS(.v14)],
    dependencies: [
        // argmaxinc/WhisperKit was renamed to argmax-oss-swift at v1.0.0 (May 2026);
        // the old URL 302s but pinning the canonical one avoids relying on that redirect.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Audium",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ],
            path: "Sources/Audium"
        )
    ]
)
