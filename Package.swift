// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DocuMind",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .executableTarget(
            name: "DocuMind",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/DocuMind"
        ),
        .testTarget(
            name: "DocuMindTests",
            dependencies: ["DocuMind"],
            path: "Tests/DocuMindTests"
        )
    ]
)
