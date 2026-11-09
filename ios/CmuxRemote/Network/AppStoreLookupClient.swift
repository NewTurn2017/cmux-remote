import Foundation

struct AppStoreListing: Equatable, Sendable {
    let version: String
    let url: URL
    let minimumOSVersion: String?
}

protocol AppStoreLookup: Sendable {
    /// Returns `nil` when the store has no listing for the bundle in that country.
    func listing(bundleID: String, country: String?) async throws -> AppStoreListing?
}

/// Reads the public iTunes lookup endpoint. The request carries only the bundle ID and country code.
struct ITunesAppStoreLookup: AppStoreLookup {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func requestURL(bundleID: String, country: String?) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        var items = [URLQueryItem(name: "bundleId", value: bundleID)]
        if let country {
            items.append(URLQueryItem(name: "country", value: country))
        }
        components.queryItems = items
        guard let url = components.url else {
            preconditionFailure("iTunes lookup URL components are static")
        }
        return url
    }

    func listing(bundleID: String, country: String?) async throws -> AppStoreListing? {
        let request = URLRequest(
            url: Self.requestURL(bundleID: bundleID, country: country),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let result = payload.results.first, let url = URL(string: result.trackViewUrl) else {
            return nil
        }
        return AppStoreListing(version: result.version, url: url, minimumOSVersion: result.minimumOsVersion)
    }
}

struct FixtureAppStoreLookup: AppStoreLookup {
    let fixture: AppStoreListing?

    func listing(bundleID: String, country: String?) async throws -> AppStoreListing? {
        fixture
    }
}

private struct LookupResponse: Decodable {
    let results: [LookupResult]
}

private struct LookupResult: Decodable {
    let version: String
    let trackViewUrl: String
    let minimumOsVersion: String?
}
