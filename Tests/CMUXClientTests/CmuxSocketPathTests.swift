import XCTest
@testable import CMUXClient

final class CmuxSocketPathTests: XCTestCase {
    func testEnvOverrideWins() {
        let p = cmuxSocketPath(["CMUX_SOCKET_PATH": "/tmp/explicit.sock"])
        XCTAssertEqual(p, "/tmp/explicit.sock")
    }
    func testLegacyAliasFallback() {
        let p = cmuxSocketPath(["CMUX_SOCKET": "/tmp/legacy.sock"])
        XCTAssertEqual(p, "/tmp/legacy.sock")
    }
    func testDefaultsToStateDir() {
        // No markers anywhere → modern XDG state socket path is the fallback.
        let p = cmuxSocketPath(
            ["HOME": "/Users/x"],
            appSupportDirectory: URL(fileURLWithPath: "/Users/x/Library/Application Support"),
            stateDirectory: URL(fileURLWithPath: "/Users/x/.local/state"),
            tmpMarkerPath: noTmpMarker()
        )
        XCTAssertEqual(p, "/Users/x/.local/state/cmux/cmux.sock")
    }

    func testFollowsTmpMarkerFirst() throws {
        let temp = freshTemp()
        let stateDir = try makeCmuxDir(temp.appendingPathComponent("state"))
        let legacyDir = try makeCmuxDir(temp.appendingPathComponent("appsupport"))
        let tmpSocket = makeSocket(stateDir, "tmp-live.sock")
        let stateSocket = makeSocket(stateDir, "state-live.sock")
        let legacySocket = makeSocket(legacyDir, "legacy-live.sock")
        let tmpMarker = temp.appendingPathComponent("tmp-marker")
        try "\(tmpSocket)\n".write(to: tmpMarker, atomically: true, encoding: .utf8)
        try writeMarker(stateDir, to: stateSocket)
        try writeMarker(legacyDir, to: legacySocket)

        let p = cmuxSocketPath(
            [:],
            appSupportDirectory: temp.appendingPathComponent("appsupport"),
            stateDirectory: temp.appendingPathComponent("state"),
            tmpMarkerPath: tmpMarker.path
        )

        XCTAssertEqual(p, tmpSocket)
    }

    func testStateMarkerPreferredOverLegacy() throws {
        let temp = freshTemp()
        let stateDir = try makeCmuxDir(temp.appendingPathComponent("state"))
        let legacyDir = try makeCmuxDir(temp.appendingPathComponent("appsupport"))
        let stateSocket = makeSocket(stateDir, "state-live.sock")
        let legacySocket = makeSocket(legacyDir, "legacy-live.sock")
        try writeMarker(stateDir, to: stateSocket)
        try writeMarker(legacyDir, to: legacySocket)

        let p = cmuxSocketPath(
            [:],
            appSupportDirectory: temp.appendingPathComponent("appsupport"),
            stateDirectory: temp.appendingPathComponent("state"),
            tmpMarkerPath: noTmpMarker()
        )

        XCTAssertEqual(p, stateSocket)
    }

    func testFollowsLegacyMarkerWhenNewerAbsent() throws {
        let temp = freshTemp()
        let legacyDir = try makeCmuxDir(temp.appendingPathComponent("appsupport"))
        let legacySocket = makeSocket(legacyDir, "cmux-501.sock")
        try writeMarker(legacyDir, to: legacySocket)

        let p = cmuxSocketPath(
            [:],
            appSupportDirectory: temp.appendingPathComponent("appsupport"),
            stateDirectory: temp.appendingPathComponent("empty-state"),
            tmpMarkerPath: noTmpMarker()
        )

        XCTAssertEqual(p, legacySocket)
    }

    func testRespectsXdgStateHomeForStateMarker() throws {
        let temp = freshTemp()
        let xdg = temp.appendingPathComponent("xdgstate")
        let stateDir = try makeCmuxDir(xdg)
        let stateSocket = makeSocket(stateDir, "xdg-live.sock")
        try writeMarker(stateDir, to: stateSocket)

        let p = cmuxSocketPath(
            ["XDG_STATE_HOME": xdg.path],
            appSupportDirectory: temp.appendingPathComponent("appsupport"),
            tmpMarkerPath: noTmpMarker()
        )

        XCTAssertEqual(p, stateSocket)
    }

    func testSkipsStaleMarkersAndFallsBackToStateSocket() throws {
        let temp = freshTemp()
        let stateDir = try makeCmuxDir(temp.appendingPathComponent("state"))
        let legacyDir = try makeCmuxDir(temp.appendingPathComponent("appsupport"))
        // Every marker points at a socket that no longer exists.
        let tmpMarker = temp.appendingPathComponent("tmp-marker")
        try "/tmp/no-such-tmp.sock\n".write(to: tmpMarker, atomically: true, encoding: .utf8)
        try writeMarker(stateDir, to: "/tmp/no-such-state.sock")
        try writeMarker(legacyDir, to: "/tmp/no-such-legacy.sock")

        let p = cmuxSocketPath(
            [:],
            appSupportDirectory: temp.appendingPathComponent("appsupport"),
            stateDirectory: temp.appendingPathComponent("state"),
            tmpMarkerPath: tmpMarker.path
        )

        XCTAssertEqual(p, stateDir.appendingPathComponent("cmux.sock").path)
    }

    func testEnvOverrideWinsOverMarkers() throws {
        let temp = freshTemp()
        let stateDir = try makeCmuxDir(temp.appendingPathComponent("state"))
        let stateSocket = makeSocket(stateDir, "state-live.sock")
        let tmpMarker = temp.appendingPathComponent("tmp-marker")
        try "\(stateSocket)\n".write(to: tmpMarker, atomically: true, encoding: .utf8)
        try writeMarker(stateDir, to: stateSocket)

        let p = cmuxSocketPath(
            ["CMUX_SOCKET_PATH": "/tmp/explicit.sock"],
            appSupportDirectory: temp.appendingPathComponent("appsupport"),
            stateDirectory: temp.appendingPathComponent("state"),
            tmpMarkerPath: tmpMarker.path
        )

        XCTAssertEqual(p, "/tmp/explicit.sock")
    }

    func testSocketPasswordEnvWins() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("cmux", isDirectory: true), withIntermediateDirectories: true)
        try "file-secret\n".write(to: temp.appendingPathComponent("cmux/socket-control-password"), atomically: true, encoding: .utf8)

        let password = cmuxSocketPassword(
            ["CMUX_SOCKET_PASSWORD": " env-secret\n"],
            appSupportDirectory: temp,
            stateDirectory: temp.appendingPathComponent("state")
        )

        XCTAssertEqual(password, "env-secret")
    }

    func testSocketPasswordFallsBackToCmuxPasswordFile() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("cmux", isDirectory: true), withIntermediateDirectories: true)
        try "file-secret\n".write(to: temp.appendingPathComponent("cmux/socket-control-password"), atomically: true, encoding: .utf8)

        let password = cmuxSocketPassword(
            [:],
            appSupportDirectory: temp,
            stateDirectory: temp.appendingPathComponent("state")
        )

        XCTAssertEqual(password, "file-secret")
    }

    func testSocketPasswordIgnoresMissingOrBlankValues() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("cmux", isDirectory: true), withIntermediateDirectories: true)
        try "\n".write(to: temp.appendingPathComponent("cmux/socket-control-password"), atomically: true, encoding: .utf8)

        let password = cmuxSocketPassword(
            ["CMUX_SOCKET_PASSWORD": "   "],
            appSupportDirectory: temp,
            stateDirectory: temp.appendingPathComponent("state")
        )

        XCTAssertNil(password)
    }

    func testSocketPasswordPrefersStateDirectoryOverLegacyFile() throws {
        let temp = freshTemp()
        let state = temp.appendingPathComponent("state")
        let appSupport = temp.appendingPathComponent("appsupport")
        try makeCmuxDir(state)
        try makeCmuxDir(appSupport)
        try "state-secret\n".write(
            to: state.appendingPathComponent("cmux/socket-control-password"),
            atomically: true,
            encoding: .utf8
        )
        try "legacy-secret\n".write(
            to: appSupport.appendingPathComponent("cmux/socket-control-password"),
            atomically: true,
            encoding: .utf8
        )

        let password = cmuxSocketPassword(
            [:],
            appSupportDirectory: appSupport,
            stateDirectory: state
        )

        XCTAssertEqual(password, "state-secret")
    }

    func testSocketCapabilityEnvWinsOverFile() throws {
        let directory = freshTemp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capabilityFile = directory.appendingPathComponent("socket-capability")
        try "file-capability\n".write(to: capabilityFile, atomically: true, encoding: .utf8)

        let capability = cmuxSocketCapability(
            ["CMUX_SOCKET_CAPABILITY": " env-capability\n"],
            capabilityFile: capabilityFile
        )

        XCTAssertEqual(capability, "env-capability")
    }

    func testSocketCapabilityFallsBackToRelayFile() throws {
        let directory = freshTemp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capabilityFile = directory.appendingPathComponent("socket-capability")
        try "v1.nonce.signature\n".write(to: capabilityFile, atomically: true, encoding: .utf8)

        let capability = cmuxSocketCapability([:], capabilityFile: capabilityFile)

        XCTAssertEqual(capability, "v1.nonce.signature")
    }

    func testSocketCapabilityRejectsWhitespaceInsideToken() throws {
        let directory = freshTemp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capabilityFile = directory.appendingPathComponent("socket-capability")
        try "invalid capability\n".write(to: capabilityFile, atomically: true, encoding: .utf8)

        XCTAssertNil(cmuxSocketCapability([:], capabilityFile: capabilityFile))
        XCTAssertNil(cmuxSocketCapability(
            ["CMUX_SOCKET_CAPABILITY": "  "],
            capabilityFile: directory.appendingPathComponent("missing-capability")
        ))
    }

    // MARK: - Helpers
    //
    // cmuxSocketPath() defaults read real machine paths (/tmp/cmux-last-socket-path,
    // ~/.local/state, ~/Library/Application Support). Every test isolates all
    // three marker tiers so results never depend on the host's live cmux.

    private func freshTemp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    /// A `/tmp` marker path guaranteed not to exist, to neutralize that tier.
    private func noTmpMarker() -> String {
        "/tmp/cmux-iphone-tests-no-such-marker-\(UUID().uuidString)"
    }

    /// Creates `<root>/cmux` and returns it.
    @discardableResult
    private func makeCmuxDir(_ root: URL) throws -> URL {
        let dir = root.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates an empty file standing in for a live socket; returns its path.
    private func makeSocket(_ dir: URL, _ name: String) -> String {
        let socket = dir.appendingPathComponent(name, isDirectory: false)
        _ = FileManager.default.createFile(atPath: socket.path, contents: Data())
        return socket.path
    }

    /// Writes a `last-socket-path` marker inside `dir` pointing at `target`.
    private func writeMarker(_ dir: URL, to target: String) throws {
        try "\(target)\n".write(
            to: dir.appendingPathComponent("last-socket-path", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

}
