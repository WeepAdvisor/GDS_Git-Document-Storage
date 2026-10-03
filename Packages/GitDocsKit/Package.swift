// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitDocsKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "SyncCore", targets: ["SyncCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "GitHubKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Persistence",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SyncCore",
            dependencies: ["GitHubKit", "Persistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GitHubKitTests",
            dependencies: ["GitHubKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"]
        ),
        .testTarget(
            name: "SyncCoreTests",
            dependencies: ["SyncCore"]
        ),
    ]
)
