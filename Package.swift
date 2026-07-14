// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lumeshot",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .executableTarget(name: "LumeshotApp", dependencies: ["LumeshotCore", "LumeshotCapture", "LumeshotUpload", "LumeshotAnnotate", "LumeshotRecord"]),
        .target(name: "LumeshotCore"),
        .target(name: "LumeshotCapture", dependencies: ["LumeshotCore"]),
        .systemLibrary(name: "Clibcurl", providers: [.brew(["curl"])]),
        .target(name: "LumeshotUpload", dependencies: [
            "LumeshotCore",
            "Clibcurl",
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "LumeshotAnnotate"),
        .target(name: "LumeshotRecord", dependencies: ["LumeshotCore"]),
        .testTarget(name: "LumeshotCoreTests", dependencies: ["LumeshotCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "LumeshotCaptureTests", dependencies: ["LumeshotCapture"]),
        .testTarget(name: "LumeshotUploadTests", dependencies: ["LumeshotUpload"]),
        .testTarget(name: "LumeshotAnnotateTests", dependencies: ["LumeshotAnnotate"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "LumeshotRecordTests", dependencies: ["LumeshotRecord"]),
    ]
)
