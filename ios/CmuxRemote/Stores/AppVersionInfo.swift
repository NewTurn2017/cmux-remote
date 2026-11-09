import Foundation

struct AppVersionInfo: Equatable, Sendable {
    let marketing: String
    let build: String

    init(marketing: String, build: String) {
        self.marketing = marketing
        self.build = build
    }

    init(infoDictionary: [String: Any]?) {
        marketing = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    static var current: AppVersionInfo {
        AppVersionInfo(infoDictionary: Bundle.main.infoDictionary)
    }

    var displayText: String { "\(marketing) (\(build))" }
}

/// `X`, `X.Y`, or `X.Y.Z` with non-negative integers; missing parts count as zero.
struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = Int(part) else {
                return nil
            }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
