import Testing
@testable import RelayServer

@Suite("ArtifactPathDetector")
struct ArtifactPathDetectorTests {
    private let detector = ArtifactPathDetector()

    @Test(
        "bare relative candidates are accepted",
        arguments: [
            ("docs/plan.md", "docs/plan.md"),
            ("README.md", "README.md"),
            ("src/a/b.swift:12:3", "src/a/b.swift"),
            ("node_modules/@scope/pkg/index.js", "node_modules/@scope/pkg/index.js"),
            ("(docs/plan.md),", "docs/plan.md"),
            ("Sources/RelayServer", "Sources/RelayServer"),
            ("CHANGELOG.MD", "CHANGELOG.MD"),
            ("[plan](docs/plan.md)", "docs/plan.md"),
        ]
    )
    func bareRelativeCandidatesAccepted(token: String, expected: String) {
        #expect(detector.paths(in: "see \(token) now") == [expected])
    }

    @Test(
        "bare noise is rejected",
        arguments: [
            "https://example.com/a.md", "ftp://host/README.md", "-x", "--flag", "--out=docs/a.md",
            "1.2.3", "v2.0.1", "example.com", "a@b.com", "1/2", "2026/11/08", "~/notes.md",
            "notes", "e.g", "plain words only",
        ]
    )
    func bareRelativeNoiseRejected(text: String) {
        #expect(detector.paths(in: text).isEmpty)
    }

    @Test("bare candidates are deduplicated and capped without limiting anchored paths")
    func bareCandidatesCappedAt64AndDeduplicated() {
        let bare = (0..<100).map { "f\($0).md" }
        let text = (["README.md", "README.md"] + bare + ["/abs/after.png", "./after.png"]).joined(separator: " ")

        let paths = detector.paths(in: text)

        #expect(ArtifactPathDetector.bareRelativeLimit == 64)
        #expect(paths.count == 66)
        #expect(paths.first == "README.md")
        #expect(paths.filter { $0 == "README.md" }.count == 1)
        #expect(paths[63] == "f62.md")
        #expect(paths.suffix(2) == ["/abs/after.png", "./after.png"])
    }

    @Test("existing absolute, dot-relative, and file URL detection keeps its order and duplicates")
    func existingAbsoluteAndDotRelativeOrderUnchanged() {
        let text = "/abs/one.png ./rel.png ../up.png docs/x.md file:///tmp/f.png /abs/one.png https://h/a.png"

        #expect(detector.paths(in: text) == [
            "/abs/one.png", "./rel.png", "../up.png", "docs/x.md", "/tmp/f.png", "/abs/one.png",
        ])
    }
}
