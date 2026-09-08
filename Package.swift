// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "reminders-mcp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "reminders-mcp",
            path: "Sources/reminders-mcp"
        )
    ]
)
