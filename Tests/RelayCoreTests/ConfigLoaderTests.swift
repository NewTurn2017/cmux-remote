import XCTest
@testable import RelayCore

final class ConfigLoaderTests: XCTestCase {
    func testParsesAllFields() throws {
        let json = #"""
        {
          "listen": "0.0.0.0:4399",
          "allow_login": ["alice@example.com"],
          "apns": { "key_path": "/k.p8", "key_id": "K", "team_id": "T",
                    "topic": "com.example", "env": "prod" },
          "snippets": [{ "label": "ll", "text": "ls -alh\n" }],
          "default_fps": 15,
          "idle_fps": 5
        }
        """#
        let cfg = try RelayConfig.decode(jsonString: json)
        XCTAssertEqual(cfg.listen, "0.0.0.0:4399")
        XCTAssertEqual(cfg.allowLogin, ["alice@example.com"])
        XCTAssertEqual(cfg.apns.keyId, "K")
        XCTAssertEqual(cfg.snippets.first?.label, "ll")
        XCTAssertEqual(cfg.defaultFps, 15)
    }

    func testRejectsMissingApns() {
        let json = #"{"listen":"x","allow_login":[],"snippets":[],"default_fps":15,"idle_fps":5}"#
        XCTAssertThrowsError(try RelayConfig.decode(jsonString: json))
    }

    func testReloadFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        let raw = #"""
        {"listen":"0.0.0.0:4399","allow_login":["a"],
         "apns":{"key_path":"/k","key_id":"K","team_id":"T","topic":"x","env":"prod"},
         "snippets":[],"default_fps":15,"idle_fps":5}
        """#
        try raw.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: url)
        try store.reload()
        XCTAssertEqual(store.current.allowLogin, ["a"])
    }
}
