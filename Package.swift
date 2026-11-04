// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentMonitor",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "AgentMonitorCore",
            targets: ["AgentMonitorCore"]
        ),
        .executable(
            name: "AgentMonitor",
            targets: ["AgentMonitor"]
        ),
        .executable(
            name: "probe",
            targets: ["probe"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AgentMonitorCore",
            dependencies: [],
            path: "Sources/AgentMonitorCore",
            resources: [.copy("Resources/PaseoBridge.cjs")]
        ),
        .executableTarget(
            name: "AgentMonitor",
            dependencies: ["AgentMonitorCore"],
            path: "Sources/AgentMonitor"
        ),
        .executableTarget(
            name: "probe",
            dependencies: ["AgentMonitorCore"],
            path: "Sources/Probe"
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
        ),
        .testTarget(
            name: "AgentMonitorTests",
            dependencies: ["AgentMonitor", "AgentMonitorCore"],
            path: "Tests/AgentMonitorTests",
            swiftSettings: [
                .unsafeFlags([
                    "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
                ])
            ]
        )
    ]
)
