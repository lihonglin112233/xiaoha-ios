// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XiaoHaCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "XiaoHaCore", targets: ["XiaoHaCore"])],
    targets: [
        .target(name: "XiaoHaCore", path: "Sources/XiaoHaCore"),
        .testTarget(name: "XiaoHaCoreTests", dependencies: ["XiaoHaCore"], path: "Tests/XiaoHaCoreTests", resources: [.copy("golden.tsv"), .copy("Fixtures")]),
    ]
)
