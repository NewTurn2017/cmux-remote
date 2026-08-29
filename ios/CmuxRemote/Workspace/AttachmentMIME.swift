import Foundation

struct AttachmentMIME {
    static func type(filename: String, declared: String?) -> String {
        if let fileExtension = AttachmentName.fileExtension(of: filename), let known = known[fileExtension] {
            return known
        }
        guard let declared, Self.isValid(declared) else { return "application/octet-stream" }
        return declared.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let known: [String: String] = [
        "pdf": "application/pdf",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "hwp": "application/x-hwp",
        "hwpx": "application/vnd.hancom.hwpx",
        "zip": "application/zip",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
        "heic": "image/heic",
        "heif": "image/heif",
        "webp": "image/webp",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "bmp": "image/bmp",
        "svg": "image/svg+xml"
    ]

    private static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections = trimmed.split(separator: ";", omittingEmptySubsequences: false)
        let components = sections[0].split(separator: "/", omittingEmptySubsequences: false)
        let tokenCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty }) else { return false }
        guard components.allSatisfy({ $0.unicodeScalars.allSatisfy { tokenCharacters.contains($0) } }) else { return false }
        return sections.dropFirst().allSatisfy { parameter in
            let normalizedParameter = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = normalizedParameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty,
                  name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }) else { return false }
            if value.first == "\"" {
                return value.last == "\"" && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            }
            return value.unicodeScalars.allSatisfy { tokenCharacters.contains($0) }
        }
    }
}
