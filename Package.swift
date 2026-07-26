// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgentUsage", targets: ["AgentUsage"]),
        .executable(
            name: "AgentUsageClaudeHelper",
            targets: ["AgentUsageClaudeHelper"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.9.2"),
    ],
    targets: [
        .executableTarget(
            name: "AgentUsage",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .executableTarget(
            name: "AgentUsageClaudeHelper"),
    ])
