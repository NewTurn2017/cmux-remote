import Foundation
import Testing
@testable import SharedKit

@Suite("cmux Remote version")
struct CmuxRemoteVersionTests {
    @Test func marketingVersionIsThreeIntegers() {
        let parts = CmuxRemoteVersion.marketing.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
    }

    @Test func iosProjectVersionsMatchSharedConstant() throws {
        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/project.yml")
        let project = try String(contentsOf: projectFile, encoding: .utf8)

        let marketing = values(of: "CFBundleShortVersionString", in: project)
        #expect(marketing.count == 3, "CFBundleShortVersionString values: \(marketing)")
        #expect(marketing.allSatisfy { $0 == CmuxRemoteVersion.marketing }, "CFBundleShortVersionString values: \(marketing)")

        let builds = values(of: "CFBundleVersion", in: project)
        #expect(builds.count == 3, "CFBundleVersion values: \(builds)")
        #expect(Set(builds).count == 1, "CFBundleVersion values: \(builds)")
    }

    private func values(of key: String, in yaml: String) -> [String] {
        yaml.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { return nil }
            return trimmed.dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }
}
