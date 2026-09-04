import XCTest
import NIOHTTP1
@testable import RelayServer
@testable import RelayCore

/// Covers the browser-client file serving added alongside `/v1/*`: the
/// happy path, the containment guard, and — just as important — that turning
/// it on doesn't change how the API namespace answers.
final class StaticFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func makeRoutes(webRoot: URL?) throws -> Routes {
        var cfg = RelayConfig.testValue
        cfg.allowLogin = ["a@b"]
        return Routes(deviceStore: try DeviceStore.empty(),
                      config: cfg,
                      auth: MockAuthService(peers: [:]),
                      allowLocalhost: false,
                      webRoot: webRoot)
    }

    private func get(_ path: String, webRoot: URL?) async throws -> HTTPResponseLite {
        let routes = try makeRoutes(webRoot: webRoot)
        return await routes.handle(method: .GET, path: path, body: nil,
                                   deviceId: nil, remoteAddr: "100.64.0.5")
    }

    // MARK: - Serving

    func testRootServesIndexHtml() async throws {
        try write("<h1>cmux</h1>", to: "index.html")
        let resp = try await get("/", webRoot: root)
        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(resp.body.map { String(decoding: $0, as: UTF8.self) }, "<h1>cmux</h1>")
        XCTAssertEqual(resp.contentType, "text/html; charset=utf-8")
    }

    func testServedFilesAreNotCached() async throws {
        // A cached `index.html` on a phone looks exactly like "the fix didn't
        // deploy" — and cost a debugging round trip before this header existed.
        try write("<h1>cmux</h1>", to: "index.html")
        let resp = try await get("/", webRoot: root)
        XCTAssertEqual(resp.cacheControl, "no-store")
    }

    func testApiResponsesCarryNoCacheHeader() async throws {
        // The header is scoped to static files; the JSON API is untouched.
        let resp = try await get("/v1/health", webRoot: root)
        XCTAssertNil(resp.cacheControl)
        XCTAssertNil(resp.contentType)
    }

    func testScriptIsServedAsJavaScript() async throws {
        // A wrong type here doesn't 404 — the browser downloads the file and
        // then refuses to execute it, which is far harder to diagnose.
        try write("export const x = 1", to: "app.js")
        let resp = try await get("/app.js", webRoot: root)
        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(resp.contentType, "text/javascript; charset=utf-8")
    }

    func testQueryStringIsIgnoredWhenResolvingFile() async throws {
        try write("body{}", to: "style.css")
        let resp = try await get("/style.css?v=3", webRoot: root)
        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(resp.contentType, "text/css; charset=utf-8")
    }

    func testNestedAssetIsServed() async throws {
        try write("{}", to: "vendor/xterm.json")
        let resp = try await get("/vendor/xterm.json", webRoot: root)
        XCTAssertEqual(resp.status, .ok)
    }

    func testMissingFileIsNotFound() async throws {
        let resp = try await get("/nope.html", webRoot: root)
        XCTAssertEqual(resp.status, .notFound)
    }

    func testDirectoryIsNotListed() async throws {
        try write("{}", to: "vendor/xterm.json")
        let resp = try await get("/vendor", webRoot: root)
        XCTAssertEqual(resp.status, .notFound)
    }

    // MARK: - Containment

    func testParentTraversalIsForbidden() async throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("cmux-outside-\(UUID()).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let resp = try await get("/../\(outside.lastPathComponent)", webRoot: root)
        XCTAssertEqual(resp.status, .forbidden)
    }

    func testPercentEncodedTraversalIsForbidden() async throws {
        let resp = try await get("/%2e%2e/%2e%2e/etc/passwd", webRoot: root)
        XCTAssertEqual(resp.status, .forbidden)
    }

    func testAbsolutePathIsConfinedToRoot() async throws {
        // `//etc/passwd` collapses to `etc/passwd` *under the root*, so this
        // must miss rather than read the real file.
        let resp = try await get("//etc/passwd", webRoot: root)
        XCTAssertEqual(resp.status, .notFound)
    }

    func testSiblingDirectoryWithSharedPrefixIsForbidden() async throws {
        // A plain string-prefix containment check would let `<root>-evil`
        // through; the component-wise check must not.
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: sibling.appendingPathComponent("x.txt"))
        defer { try? FileManager.default.removeItem(at: sibling) }

        let resp = try await get("/../\(sibling.lastPathComponent)/x.txt", webRoot: root)
        XCTAssertEqual(resp.status, .forbidden)
    }

    // MARK: - Interaction with the API namespace

    func testApiNamespaceNeverFallsThroughToDisk() async throws {
        // A file literally named `v1/health` must not shadow or stand in for
        // an API route; unknown `/v1/*` paths stay 404.
        try write("owned", to: "v1/whoami")
        let resp = try await get("/v1/whoami", webRoot: root)
        XCTAssertEqual(resp.status, .notFound)
        XCTAssertNil(resp.body)
    }

    func testHealthStillAnswersWithWebRootConfigured() async throws {
        try write("<h1>cmux</h1>", to: "index.html")
        let resp = try await get("/v1/health", webRoot: root)
        XCTAssertEqual(resp.status, .ok)
    }

    func testNonGetMethodIsNotServed() async throws {
        try write("<h1>cmux</h1>", to: "index.html")
        let routes = try makeRoutes(webRoot: root)
        let resp = await routes.handle(method: .POST, path: "/index.html", body: nil,
                                       deviceId: nil, remoteAddr: "100.64.0.5")
        XCTAssertEqual(resp.status, .notFound)
    }

    func testWithoutWebRootUnknownPathsStay404() async throws {
        let resp = try await get("/", webRoot: nil)
        XCTAssertEqual(resp.status, .notFound)
        XCTAssertNil(resp.contentType)
    }

    // MARK: - Config resolution

    func testResolvedWebRootFallsBackToNilWhenDirectoryMissing() {
        let missing = root.appendingPathComponent("does-not-exist").path
        XCTAssertNil(Serve.resolvedWebRoot(configured: missing))
    }

    func testResolvedWebRootUsesConfiguredDirectory() {
        XCTAssertEqual(Serve.resolvedWebRoot(configured: root.path)?.path, root.path)
    }

    func testWebRootDecodesFromRelayJson() throws {
        let cfg = try RelayConfig.decode(jsonString: #"{"web_root":"/tmp/web"}"#)
        XCTAssertEqual(cfg.webRoot, "/tmp/web")
    }

    func testWebRootDefaultsToEmptyWhenAbsent() throws {
        let cfg = try RelayConfig.decode(jsonString: #"{"listen":"0.0.0.0:4399"}"#)
        XCTAssertEqual(cfg.webRoot, "")
    }
}
