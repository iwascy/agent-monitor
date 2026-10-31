// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AgentMonitorCore",
            targets: ["AgentMonitorCore"]
        ),
        .executable(
            name: "AgentMonitor",
            targets: ["AgentMonitor"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AgentMonitorCore",
            dependencies: [],
            path: "Sources/AgentMonitorCore"
        ),
        .executableTarget(
            name: "AgentMonitor",
            dependencies: ["AgentMonitorCore"],
            path: "Sources/AgentMonitor"
        ),
        .testTarget(
            name: "AgentMonitorCoreTests",
            dependencies: ["AgentMonitorCore"],
            path: "Tests/AgentMonitorCoreTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
                ])
            ]
        )
    ]
)
