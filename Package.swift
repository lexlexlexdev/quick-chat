// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickChat",
    platforms: [.macOS(.v14)],
    dependencies: [
        // v0.7.0 pins HighlightSwift and iosMath by revision, so SwiftPM requires a revision here too.
        .package(url: "https://github.com/microsoft/SwiftStreamingMarkdown", revision: "5f7c04e0558df6146f90d482edb62cb456986bda")
    ],
    targets: [
        .executableTarget(name: "QuickChat", dependencies: [
            .product(name: "SwiftStreamingMarkdown", package: "SwiftStreamingMarkdown")
        ]),
        .testTarget(name: "QuickChatTests", dependencies: ["QuickChat"])
    ],
    swiftLanguageModes: [.v5]
)
