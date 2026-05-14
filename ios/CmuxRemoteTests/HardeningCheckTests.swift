import XCTest
@testable import CmuxRemote

final class HardeningCheckTests: XCTestCase {
    func testFailedCheckWipesKeychain() {
        let keychain = Keychain(service: "h.\(UUID().uuidString)")
        try? keychain.set("v", for: "bearer")
        let check = HardeningCheck(jailbroken: { true }, debugged: { false }, keychain: keychain)
        XCTAssertEqual(check.runAtLaunch(), .failedJailbroken)
        XCTAssertNil(try? keychain.get("bearer"))
    }

    func testCleanCheckReturnsOk() {
        let keychain = Keychain(service: "h.\(UUID().uuidString)")
        let check = HardeningCheck(jailbroken: { false }, debugged: { false }, keychain: keychain)
        XCTAssertEqual(check.runAtLaunch(), .ok)
    }

    func testSimulatorLiveSmokeCanExplicitlyBypassHardeningInDebug() {
        #if DEBUG
        XCTAssertTrue(CmuxRemoteApp.shouldSkipHardeningForDevelopment(environment: ["CMUX_SKIP_HARDENING": "1"]))
        XCTAssertTrue(CmuxRemoteApp.shouldSkipHardeningForDevelopment(environment: [:], arguments: ["-CMUXSkipHardening"]))
        XCTAssertTrue(CmuxRemoteApp.shouldSkipHardeningForDevelopment(environment: [:]))
        #else
        XCTAssertFalse(CmuxRemoteApp.shouldSkipHardeningForDevelopment(environment: ["CMUX_SKIP_HARDENING": "1"]))
        #endif
    }
}
