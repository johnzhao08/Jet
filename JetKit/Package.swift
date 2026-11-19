// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JetKit",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "JetKit", targets: ["JetKit"]),
        // The slice the share extension, widgets and Shortcuts use: no git, no UI, small enough for an extension.
        .library(name: "JetCapture", targets: ["JetCapture"]),
    ],
    dependencies: [
        // libgit2 built from source: works on iPadOS (no git binary there) and macOS alike.
        .package(url: "https://github.com/ibrahimcetin/libgit2.git", exact: "1.9.2"),
    ],
    targets: [
        .target(name: "JetCapture"),
        .target(
            name: "JetKit",
            dependencies: ["JetCapture", .product(name: "libgit2", package: "libgit2")]
        ),
        .testTarget(name: "JetCaptureTests", dependencies: ["JetKit", "JetCapture"]),
    ],
    swiftLanguageModes: [.v5]
)
