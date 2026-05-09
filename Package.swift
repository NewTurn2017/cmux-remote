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
        // MILESTONE-GATED: re-add alongside the target that consumes them.
        // M2 re-adds: swift-nio, swift-log
        // M3 re-adds: swift-nio-ssl, swift-argument-parser, swift-crypto, async-http-client
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
