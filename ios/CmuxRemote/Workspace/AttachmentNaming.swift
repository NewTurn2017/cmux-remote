import Foundation
import UniformTypeIdentifiers

/// Pure helpers that turn a picked document into an upload filename + MIME type.
/// Deliberately free of SwiftUI and URL file-IO so it is unit-testable without
/// a device or simulator UI.
enum AttachmentNaming {
    static let fallbackMimeType = "application/octet-stream"

    /// Strips path separators and control characters, keeping only the last path
    /// component so "../../x" cannot escape the target directory. Returns "file"
    /// when nothing usable remains. The extension is preserved as-is.
    static func sanitizedBasename(_ raw: String) -> String {
        let lastComponent = raw
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let disallowed = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: ":/\\"))
        let cleaned = String(lastComponent.unicodeScalars.filter { !disallowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "file" : cleaned
    }

    /// Preferred MIME for a UTType, or the octet-stream fallback when unknown.
    static func mimeType(for contentType: UTType?) -> String {
        contentType?.preferredMIMEType ?? fallbackMimeType
    }
}
