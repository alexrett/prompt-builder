// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PromptBuilder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PromptBuilder")
    ]
)
