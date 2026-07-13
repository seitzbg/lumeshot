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
        .executableTarget(name: "SXApp", dependencies: ["SXCore", "SXCapture", "SXUpload", "SXAnnotate", "SXRecord"]),
        .target(name: "SXCore"),
        .target(name: "SXCapture", dependencies: ["SXCore"]),
        .systemLibrary(name: "Clibcurl", providers: [.brew(["curl"])]),
        .target(name: "SXUpload", dependencies: [
            "SXCore",
            "Clibcurl",
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "SXAnnotate"),
        .target(name: "SXRecord", dependencies: ["SXCore"]),
        .testTarget(name: "SXCoreTests", dependencies: ["SXCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SXCaptureTests", dependencies: ["SXCapture"]),
        .testTarget(name: "SXUploadTests", dependencies: ["SXUpload"]),
        .testTarget(name: "SXAnnotateTests", dependencies: ["SXAnnotate"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SXRecordTests", dependencies: ["SXRecord"]),
    ]
)
