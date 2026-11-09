import Foundation
import Observation

@MainActor
@Observable
final class AppStoreUpdateStore {
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private enum Keys {
        static let lastCheckedAt = "cmux.appStore.lastCheckedAt"
        static let latestVersion = "cmux.appStore.latestVersion"
        static let latestURL = "cmux.appStore.latestURL"
        static let minimumOSVersion = "cmux.appStore.minimumOSVersion"
        static let seenVersion = "cmux.appStore.seenVersion"
    }

    let installed: AppVersionInfo
    private(set) var availableUpdate: AppStoreListing?
    private(set) var seenVersion: String?

    @ObservationIgnored private let lookup: (any AppStoreLookup)?
    @ObservationIgnored private let bundleID: String?
    @ObservationIgnored private let country: String?
    @ObservationIgnored private let systemVersion: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var isChecking = false

    init(
        lookup: (any AppStoreLookup)?,
        installed: AppVersionInfo,
        bundleID: String?,
        country: String?,
        systemVersion: String,
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init
    ) {
        self.lookup = lookup
        self.installed = installed
        self.bundleID = bundleID
        self.country = country
        self.systemVersion = systemVersion
        self.defaults = defaults
        self.now = now
        seenVersion = defaults.string(forKey: Keys.seenVersion)
        availableUpdate = newerListing(cachedListing())
    }

    var showsBadge: Bool {
        guard let availableUpdate else { return false }
        return availableUpdate.version != seenVersion
    }

    /// Looks up the store at most once per `checkInterval`; failures keep the cached result silently.
    func checkIfDue() async {
        guard let lookup, let bundleID, !isChecking else { return }
        if let lastCheckedAt = defaults.object(forKey: Keys.lastCheckedAt) as? Date,
           now().timeIntervalSince(lastCheckedAt) < Self.checkInterval {
            return
        }
        isChecking = true
        defer { isChecking = false }
        defaults.set(now(), forKey: Keys.lastCheckedAt)

        let listing: AppStoreListing?
        do {
            if let regional = try await lookup.listing(bundleID: bundleID, country: country) {
                listing = regional
            } else if country != nil {
                listing = try await lookup.listing(bundleID: bundleID, country: nil)
            } else {
                listing = nil
            }
        } catch {
            return
        }
        cache(listing)
        availableUpdate = newerListing(listing)
    }

    func markSeen() {
        guard let version = availableUpdate?.version, version != seenVersion else { return }
        seenVersion = version
        defaults.set(version, forKey: Keys.seenVersion)
    }

    private func newerListing(_ listing: AppStoreListing?) -> AppStoreListing? {
        guard let listing,
              let storeVersion = SemanticVersion(listing.version),
              let installedVersion = SemanticVersion(installed.marketing),
              storeVersion > installedVersion
        else { return nil }
        if let minimumOSVersion = listing.minimumOSVersion {
            guard let required = SemanticVersion(minimumOSVersion),
                  let system = SemanticVersion(systemVersion),
                  required <= system
            else { return nil }
        }
        return listing
    }

    private func cachedListing() -> AppStoreListing? {
        guard let version = defaults.string(forKey: Keys.latestVersion),
              let urlText = defaults.string(forKey: Keys.latestURL),
              let url = URL(string: urlText)
        else { return nil }
        return AppStoreListing(
            version: version,
            url: url,
            minimumOSVersion: defaults.string(forKey: Keys.minimumOSVersion)
        )
    }

    private func cache(_ listing: AppStoreListing?) {
        defaults.set(listing?.version, forKey: Keys.latestVersion)
        defaults.set(listing?.url.absoluteString, forKey: Keys.latestURL)
        defaults.set(listing?.minimumOSVersion, forKey: Keys.minimumOSVersion)
    }
}
