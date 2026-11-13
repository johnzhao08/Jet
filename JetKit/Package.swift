// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JetKit",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "JetKit", targets: ["JetKit"]),
    ],
    dependencies: [
        // libgit2 built from source: works on iPadOS (no git binary there) and macOS alike.
        .package(url: "https://github.com/ibrahimcetin/libgit2.git", exact: "1.9.2"),
    ],
    targets: [
        .target(
            name: "JetKit",
            dependencies: [.product(name: "libgit2", package: "libgit2")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
