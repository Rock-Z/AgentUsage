// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgentUsage", targets: ["AgentUsage"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentUsage"),
    ])
