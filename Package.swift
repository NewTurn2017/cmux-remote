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
        .executable(name: "cmux-relay", targets: ["RelayServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git",            from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git",            from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git",        from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git",         from: "3.4.0"),
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.21.0"),
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
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        .executableTarget(
            name: "RelayServer",
            dependencies: [
                "RelayCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "SharedKitTests",  dependencies: ["SharedKit"]),
        .testTarget(name: "CMUXClientTests", dependencies: [
            "CMUXClient",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
        .testTarget(name: "DiffEngineTests", dependencies: [
            "RelayCore",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ], resources: [
            .copy("Fixtures"),
        ]),
        .testTarget(name: "RelayCoreTests", dependencies: [
            "RelayCore",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
        .testTarget(name: "RelayServerTests", dependencies: [
            "RelayServer",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
    ]
)
