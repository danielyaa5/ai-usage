// swift-tools-version: 5.9
import PackageDescription

// The data model, formatting and the dashboard client, shared by the app and the widget extension.
// Static, so each of them links it directly and the extension has no framework to embed.
let package = Package(
    name: "AIUsageKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIUsageKit", type: .static, targets: ["AIUsageKit"]),
    ],
    targets: [
        .target(name: "AIUsageKit"),
        .testTarget(name: "AIUsageKitTests", dependencies: ["AIUsageKit"]),
    ]
)
