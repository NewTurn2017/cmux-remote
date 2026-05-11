import XCTest
import ArgumentParser
@testable import RelayServer

/// Argument-parsing surface for the `cmux-relay` CLI. Business logic
/// inside `run()` (filesystem reads, NIO bootstrap, signal handling) is
/// exercised by the M3.13 live smoke; here we only assert the parser
/// produces the right subcommand with the right fields.
final class CmuxRelayTests: XCTestCase {

    func testServeIsDefaultSubcommand() throws {
        let cmd = try CmuxRelay.parseAsRoot([])
        XCTAssertTrue(cmd is Serve, "expected Serve, got \(type(of: cmd))")
    }

    func testServeAcceptsConfigOption() throws {
        let cmd = try CmuxRelay.parseAsRoot(["serve", "--config", "/tmp/r.json"])
        let serve = try XCTUnwrap(cmd as? Serve)
        XCTAssertEqual(serve.config, "/tmp/r.json")
    }

    func testServeDefaultsToHomeConfigPath() throws {
        let cmd = try CmuxRelay.parseAsRoot(["serve"])
        let serve = try XCTUnwrap(cmd as? Serve)
        XCTAssertTrue(serve.config.hasSuffix("/.cmuxremote/relay.json"),
                      "default config should live under ~/.cmuxremote/; got \(serve.config)")
    }

    func testDevicesListParses() throws {
        let cmd = try CmuxRelay.parseAsRoot(["devices", "list"])
        XCTAssertTrue(cmd is Devices.List, "expected Devices.List, got \(type(of: cmd))")
    }

    func testDevicesRevokeRequiresDeviceId() {
        XCTAssertThrowsError(try CmuxRelay.parseAsRoot(["devices", "revoke"]))
    }

    func testDevicesRevokeAcceptsDeviceId() throws {
        let cmd = try CmuxRelay.parseAsRoot(["devices", "revoke", "abc-xyz"])
        let revoke = try XCTUnwrap(cmd as? Devices.Revoke)
        XCTAssertEqual(revoke.deviceId, "abc-xyz")
    }
}
