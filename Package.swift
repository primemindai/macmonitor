// swift-tools-version: 6.0
import PackageDescription


let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MonitorCore", targets: ["MonitorCore"]),
        .executable(name: "MacMonitor", targets: ["MacMonitor"]),
        .executable(name: "macmonitor-mcp", targets: ["macmonitor-mcp"]),
    ],
    targets: [
        .target(
            name: "CSensors",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("IOReport"),
            ]
        ),
        .target(
            name: "MonitorCore",
            dependencies: ["CSensors"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("CoreWLAN"),
            ]
        ),
        .executableTarget(name: "MacMonitor", dependencies: ["MonitorCore"]),
        .executableTarget(name: "macmonitor-mcp", dependencies: ["MonitorCore"]),
        // Run tests with scripts/test.sh. On Command Line Tools, plain `swift test` builds a
        // runner that cannot see swift-testing and silently runs zero tests.
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
    ]
)
