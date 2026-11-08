import Foundation

/// How an authorized artifact can be shown in the app.
///
/// The relay reports `application/octet-stream` for many text formats
/// (logs, TOML, Swift, shell, diffs), so the decision combines the MIME type,
/// a fixed extension list, and a UTF-8 check on the loaded bytes.
enum DocumentContentKind: Equatable, Sendable {
    case image
    case markdown
    case text
    case binary

    var isDocument: Bool { self == .markdown || self == .text }

    static func classify(filename: String, mimeType: String, isImage: Bool) -> DocumentContentKind {
        if isImage { return .image }
        let mime = mimeType.lowercased()
            .split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let name = filename.lowercased()
        let ext = (name as NSString).pathExtension

        if markdownMIMETypes.contains(mime) || markdownExtensions.contains(ext) { return .markdown }
        if mime.hasPrefix("text/") || textMIMETypes.contains(mime) { return .text }
        if textExtensions.contains(ext) || textFilenames.contains(name) { return .text }
        return .binary
    }

    /// Rejects bytes that are clearly not UTF-8 text: a NUL byte or an invalid
    /// UTF-8 sequence in the leading sample. A multi-byte sequence cut by the
    /// end of the sample is allowed.
    static func isLikelyText(_ data: Data, sampleBytes: Int = 8 * 1024) -> Bool {
        let sample = data.prefix(sampleBytes)
        if sample.contains(0) { return false }
        let complete = sample.count < data.count ? UTF8Boundary.trimmingIncompleteSuffix(sample) : Data(sample)
        return String(data: complete, encoding: .utf8) != nil
    }

    private static let markdownMIMETypes: Set<String> = ["text/markdown", "text/x-markdown"]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    private static let textMIMETypes: Set<String> = [
        "application/json",
        "application/xml",
        "application/x-yaml",
        "application/yaml",
        "application/javascript",
        "application/toml",
        "application/x-sh",
    ]
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "env",
        "xml", "plist", "html", "htm", "css", "csv", "tsv", "rst", "adoc", "org", "mdx",
        "diff", "patch", "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx",
        "sh", "zsh", "bash", "fish", "go", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm",
        "java", "kt", "kts", "rb", "sql", "lock", "resolved", "gradle", "properties",
    ]
    private static let textFilenames: Set<String> = [
        "makefile", "dockerfile", "readme", "license", "gemfile", "podfile",
        ".gitignore", ".gitattributes", ".env", ".editorconfig",
    ]
}

enum UTF8Boundary {
    static func trimmingIncompleteSuffix<D: DataProtocol>(_ bytes: D) -> Data {
        let data = Data(bytes)
        guard !data.isEmpty else { return data }
        var leadIndex = data.endIndex - 1
        var continuationCount = 0
        while leadIndex > data.startIndex, data[leadIndex] & 0xC0 == 0x80, continuationCount < 3 {
            leadIndex -= 1
            continuationCount += 1
        }
        let lead = data[leadIndex]
        let expectedLength: Int
        switch lead {
        case 0x00...0x7F: expectedLength = 1
        case 0xC0...0xDF: expectedLength = 2
        case 0xE0...0xEF: expectedLength = 3
        case 0xF0...0xF7: expectedLength = 4
        default: return data
        }
        let available = data.endIndex - leadIndex
        return available < expectedLength ? data.prefix(upTo: leadIndex) : data
    }
}
