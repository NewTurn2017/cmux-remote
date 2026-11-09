import XCTest
@testable import CmuxRemote

final class LocalizationCoverageTests: XCTestCase {
    func testEveryEnglishCatalogKeyHasKoreanTranslation() throws {
        let english = try compiledTable(language: "en")
        let korean = try compiledTable(language: "ko")
        XCTAssertFalse(english.isEmpty, "compiled English catalog is empty")

        let missing = english.keys.filter { (korean[$0] ?? "").isEmpty }.sorted()
        XCTAssertEqual(missing, [], "catalog keys without a Korean translation")
    }

    func testKoreanTranslationsKeepEnglishFormatSpecifiers() throws {
        let english = try compiledTable(language: "en")
        let korean = try compiledTable(language: "ko")
        let mismatched = english.compactMap { key, value -> String? in
            guard let translated = korean[key] else { return nil }
            return formatSpecifiers(in: value) == formatSpecifiers(in: translated) ? nil : key
        }.sorted()
        XCTAssertEqual(mismatched, [], "Korean translations whose format specifiers differ from English")
    }

    private func compiledTable(language: String) throws -> [String: String] {
        let bundle = Bundle(for: WorkspaceStore.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
            "missing \(language).lproj/Localizable.strings in \(bundle.bundlePath)"
        )
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    private func formatSpecifiers(in text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|d|@|f)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
        }.sorted()
    }
}
