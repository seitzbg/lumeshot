// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sharex-mac",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SXApp", dependencies: ["SXCore", "SXCapture", "SXUpload", "SXAnnotate", "SXRecord"]),
        .target(name: "SXCore"),
        .target(name: "SXCapture", dependencies: ["SXCore"]),
        .target(name: "SXUpload", dependencies: ["SXCore"]),
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
