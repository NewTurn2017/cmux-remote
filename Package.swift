// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CmuxRemote",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SharedKit",  targets: ["SharedKit"]),
        .library(name: "CMUXClient", targets: ["CMUXClient"]),
        .library(name: "RelayCore",  targets: ["RelayCore"]),
        // MILESTONE-GATED: re-enable in M3 alongside the matching target
        // .executable(name: "cmux-relay", targets: ["RelayServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        // MILESTONE-GATED for M3: swift-nio-ssl, swift-argument-parser, swift-crypto, async-http-client
    ],
    targets: [
        .target(name: "SharedKit"),
        .target(
            name: "CMUXClient",
            dependencies: [
                "SharedKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "RelayCore",
            dependencies: [
                "SharedKit",
                "CMUXClient",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "SharedKitTests",  dependencies: ["SharedKit"]),
        .testTarget(name: "CMUXClientTests", dependencies: [
            "CMUXClient",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
        .testTarget(name: "DiffEngineTests", dependencies: [
            "RelayCore",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ], resources: [
            .copy("Fixtures"),
        ]),
        // MILESTONE-GATED: re-enable in M3
        // .executableTarget(name: "RelayServer", ...),
        // .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
        // .testTarget(name: "RelayServerTests", dependencies: ["RelayServer", ...]),
    ]
)
