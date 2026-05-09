// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CmuxRemote",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SharedKit", targets: ["SharedKit"]),
        // MILESTONE-GATED: re-enable in M2/M3 alongside the matching target
        // .library(name: "CMUXClient", targets: ["CMUXClient"]),
        // .library(name: "RelayCore",  targets: ["RelayCore"]),
        // .executable(name: "cmux-relay", targets: ["RelayServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git",            from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git",        from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-log.git",            from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-argument-parser",    from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git",         from: "3.4.0"),
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.21.0"),
    ],
    targets: [
        .target(name: "SharedKit"),
        .testTarget(name: "SharedKitTests", dependencies: ["SharedKit"]),
        // MILESTONE-GATED: re-enable in M2/M3
        // .target(name: "CMUXClient", ...),
        // .target(name: "RelayCore", ...),
        // .executableTarget(name: "RelayServer", ...),
        // .testTarget(name: "CMUXClientTests", dependencies: ["CMUXClient"]),
        // .testTarget(name: "DiffEngineTests", dependencies: ["RelayCore"]),
        // .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
    ]
)
