import XCTest
@testable import CmuxRemote

@MainActor
final class AppStoreUpdateStoreTests: XCTestCase {
    private let bundleID = "com.genie.CmuxRemote"
    private let trackViewURL = "https://apps.apple.com/kr/app/cmux-remote/id6769380881"
    private let defaultsSuite = "AppStoreUpdateStoreTests-\(UUID().uuidString)"
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private lazy var defaults: UserDefaults = {
        let suite = defaultsSuite
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }()

    func testRequestURLCarriesOnlyBundleIDAndCountry() throws {
        let url = ITunesAppStoreLookup.requestURL(bundleID: bundleID, country: "kr")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "itunes.apple.com")
        XCTAssertEqual(components.path, "/lookup")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: "kr"),
        ])
        XCTAssertEqual(
            ITunesAppStoreLookup.requestURL(bundleID: bundleID, country: nil).query,
            "bundleId=\(bundleID)"
        )
    }

    func testNewerStoreVersionIsAvailableWithTrackViewURL() async throws {
        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "2.1.0")) }
        let store = makeStore(installed: "2.0.0")

        await store.checkIfDue()

        let update = try XCTUnwrap(store.availableUpdate)
        XCTAssertEqual(update.version, "2.1.0")
        XCTAssertEqual(update.url.absoluteString, trackViewURL)
        XCTAssertTrue(store.showsBadge)
        XCTAssertEqual(StubURLProtocol.requestedCountries, ["kr"])
    }

    func testSameStoreVersionIsNotAvailable() async {
        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "2.0.0")) }
        let store = makeStore(installed: "2.0.0")

        await store.checkIfDue()

        XCTAssertNil(store.availableUpdate)
        XCTAssertFalse(store.showsBadge)
    }

    func testDevelopmentBuildAboveStoreIsNotAvailable() async {
        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "1.1.4")) }
        let store = makeStore(installed: "2.0.0")

        await store.checkIfDue()

        XCTAssertNil(store.availableUpdate)
    }

    func testEmptyRegionalResultRetriesOnceWithoutCountry() async throws {
        StubURLProtocol.respond { request in
            request.url?.query?.contains("country=") == true
                ? .json(#"{"resultCount":0,"results":[]}"#)
                : .json(self.lookupBody(version: "2.1.0"))
        }
        let store = makeStore(installed: "2.0.0")

        await store.checkIfDue()

        XCTAssertEqual(StubURLProtocol.requestedCountries, ["kr", nil])
        XCTAssertEqual(try XCTUnwrap(store.availableUpdate).version, "2.1.0")
    }

    func testServerErrorIsIgnoredAndKeepsCachedUpdate() async throws {
        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "2.1.0")) }
        await makeStore(installed: "2.0.0").checkIfDue()
        clock.addTimeInterval(AppStoreUpdateStore.checkInterval + 1)
        StubURLProtocol.respond { _ in .status(500) }
        let store = makeStore(installed: "2.0.0")

        await store.checkIfDue()

        XCTAssertEqual(StubURLProtocol.requestedCountries, ["kr"])
        XCTAssertEqual(try XCTUnwrap(store.availableUpdate).version, "2.1.0")
    }

    func testFailedLookupIsRetriedOnTheNextCall() async throws {
        StubURLProtocol.respond { _ in .status(500) }
        let store = makeStore(installed: "2.0.0")
        await store.checkIfDue()
        XCTAssertNil(store.availableUpdate)
        XCTAssertEqual(StubURLProtocol.requestedCountries, ["kr"])

        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "2.1.0")) }
        await store.checkIfDue()

        XCTAssertEqual(StubURLProtocol.requestedCountries, ["kr"], "a failure must not start the 24-hour wait")
        XCTAssertEqual(try XCTUnwrap(store.availableUpdate).version, "2.1.0")
    }

    func testMalformedResponseIsIgnoredSilently() async {
        StubURLProtocol.respond { _ in .json("not json") }
        let store = makeStore(installed: "2.0.0")

        await store.checkIfDue()

        XCTAssertNil(store.availableUpdate)
        XCTAssertEqual(StubURLProtocol.requestedCountries, ["kr"])
    }

    func testChecksAtMostOncePerDay() async {
        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "2.1.0")) }
        let store = makeStore(installed: "2.0.0")

        await store.checkIfDue()
        clock.addTimeInterval(AppStoreUpdateStore.checkInterval - 1)
        await store.checkIfDue()
        XCTAssertEqual(StubURLProtocol.requestedCountries.count, 1)

        clock.addTimeInterval(2)
        await store.checkIfDue()
        XCTAssertEqual(StubURLProtocol.requestedCountries.count, 2)
    }

    func testMinimumOSAboveDeviceHidesUpdate() async {
        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "2.1.0", minimumOS: "27.0")) }
        let store = makeStore(installed: "2.0.0", systemVersion: "26.1")

        await store.checkIfDue()

        XCTAssertNil(store.availableUpdate)
    }

    func testMarkSeenClearsBadgeButKeepsNoticeAcrossRelaunch() async throws {
        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "2.1.0")) }
        let store = makeStore(installed: "2.0.0")
        await store.checkIfDue()

        store.markSeen()

        XCTAssertFalse(store.showsBadge)
        XCTAssertNotNil(store.availableUpdate)
        let relaunched = makeStore(installed: "2.0.0")
        XCTAssertEqual(try XCTUnwrap(relaunched.availableUpdate).version, "2.1.0")
        XCTAssertFalse(relaunched.showsBadge)
        XCTAssertEqual(StubURLProtocol.requestedCountries.count, 1)
    }

    func testCachedUpdateDisappearsOnceInstalledVersionCatchesUp() async {
        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "2.1.0")) }
        await makeStore(installed: "2.0.0").checkIfDue()

        XCTAssertNil(makeStore(installed: "2.1.0").availableUpdate)
    }

    func testStoreWithoutLookupSendsNoRequests() async {
        StubURLProtocol.respond { _ in .json(self.lookupBody(version: "2.1.0")) }
        let store = AppStoreUpdateStore(
            lookup: nil,
            installed: AppVersionInfo(marketing: "2.0.0", build: "22"),
            bundleID: bundleID,
            country: "kr",
            systemVersion: "26.1",
            defaults: defaults,
            now: { self.clock }
        )

        await store.checkIfDue()

        XCTAssertTrue(StubURLProtocol.requestedCountries.isEmpty)
        XCTAssertNil(store.availableUpdate)
    }

    private func makeStore(installed: String, systemVersion: String = "26.1") -> AppStoreUpdateStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AppStoreUpdateStore(
            lookup: ITunesAppStoreLookup(session: URLSession(configuration: configuration)),
            installed: AppVersionInfo(marketing: installed, build: "22"),
            bundleID: bundleID,
            country: "kr",
            systemVersion: systemVersion,
            defaults: defaults,
            now: { self.clock }
        )
    }

    private nonisolated func lookupBody(version: String, minimumOS: String = "17.0") -> String {
        """
        {"resultCount":1,"results":[{"version":"\(version)","trackViewUrl":"\(trackViewURL)","minimumOsVersion":"\(minimumOS)","bundleId":"\(bundleID)"}]}
        """
    }
}

private enum StubResponse {
    case json(String)
    case status(Int)
}

private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> StubResponse)?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func respond(_ handler: @escaping @Sendable (URLRequest) -> StubResponse) {
        lock.withLock {
            self.handler = handler
            requests = []
        }
    }

    static var requestedCountries: [String?] {
        lock.withLock {
            requests.map { request in
                request.url
                    .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?
                    .first(where: { $0.name == "country" })?
                    .value
            }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { () -> (@Sendable (URLRequest) -> StubResponse)? in
            Self.requests.append(request)
            return Self.handler
        }
        guard let url = request.url, let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let statusCode: Int
        let body: Data
        switch handler(request) {
        case .json(let text):
            statusCode = 200
            body = Data(text.utf8)
        case .status(let code):
            statusCode = code
            body = Data()
        }
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
