// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "reminders-mcp",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure + EventKit-model logic, no stdio, no globals the tests can't stand up.
        .target(
            name: "RemindersCore",
            path: "Sources/RemindersCore"
        ),
        .executableTarget(
            name: "reminders-mcp",
            dependencies: ["RemindersCore"],
            path: "Sources/reminders-mcp"
        ),
        .testTarget(
            name: "RemindersCoreTests",
            dependencies: ["RemindersCore"],
            path: "Tests/RemindersCoreTests"
        ),
    ]
)
