// swift-tools-version: 6.0
import PackageDescription

// Tools that run without Xcode:
//   ./selftest.sh      exercises git sync, ink merging and note parsing between two simulated devices
//   ./graphcheck.sh    checks the graph's filter, depth, colour groups and background layout
//
// PencilKit and UserDefaults need a bundle identifier, which a bare executable does not have.
// Embedding an Info.plist gives these binaries one.
let embeddedInfoPlist: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Support/DevInfo.plist"]),
]

let package = Package(
    name: "JetDev",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../JetKit")],
    targets: [
        .executableTarget(name: "jet-selftest", dependencies: ["JetKit"], linkerSettings: embeddedInfoPlist),
        .executableTarget(name: "jet-graphcheck", dependencies: ["JetKit"]),
    ],
    swiftLanguageModes: [.v5]
)
