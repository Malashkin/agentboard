// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentBoard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentBoard",
            path: "Sources/AgentBoard",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
