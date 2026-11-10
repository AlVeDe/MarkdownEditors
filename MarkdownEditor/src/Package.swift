// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkdownEditor",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "MarkdownEditor",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            resources: [
                .copy("Resources/Sample.md"),
                .copy("Resources/mermaid.min.js"),
                .copy("Resources/tex-svg-full.js"),
                .copy("Resources/latex-commands.json")
            ]
        ),
        .testTarget(
            name: "MarkdownEditorTests",
            dependencies: ["MarkdownEditor"]
        )
    ]
)
