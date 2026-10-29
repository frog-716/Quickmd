// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Quickmd",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Quickmd",
            resources: [
                .copy("Resources/editor.html"),
                .copy("Resources/editor-core.js"),
                .copy("Resources/editor.js"),
                .copy("Resources/workspace.js"),
                .copy("Resources/editor.css"),
            ]
        )
    ]
)
