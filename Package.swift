// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "aiusage",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "aiusage", targets: ["aiusage"]),
    ],
    targets: [
        .executableTarget(
            name: "aiusage"),
    ])
