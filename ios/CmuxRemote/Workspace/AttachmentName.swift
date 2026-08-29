import Foundation

struct AttachmentName {
    static func normalized(_ original: String) -> String {
        let leaf = URL(fileURLWithPath: original).lastPathComponent
            .precomposedStringWithCanonicalMapping
        let sanitized = Self.trimmedTrailing(String(leaf.unicodeScalars.map { scalar in
            if scalar == "/" || scalar == "\\" || scalar.value == 0 || CharacterSet.controlCharacters.contains(scalar) || Self.isBidiControl(scalar) {
                return "-"
            }
            return Character(scalar)
        }), characters: " .-")
        let parts = sanitized.split(separator: ".", omittingEmptySubsequences: false)
        let extensionCandidate: String
        let baseCandidate: String
        if parts.count > 1 {
            extensionCandidate = String(parts.last!).lowercased()
            baseCandidate = parts.dropLast().joined(separator: ".")
        } else {
            extensionCandidate = ""
            baseCandidate = sanitized
        }
        let base = Self.trimmedBase(baseCandidate)
        let extensionName = Self.safeExtension(extensionCandidate)
        guard !base.isEmpty, let extensionName else { return "attachment.bin" }
        let cappedBase = Self.capped(base, bytes: 180)
        guard !cappedBase.isEmpty else { return "attachment.bin" }
        return "\(cappedBase).\(extensionName)"
    }

    static func fileExtension(of original: String) -> String? {
        let leaf = URL(fileURLWithPath: original).lastPathComponent
        guard let dot = leaf.lastIndex(of: "."), dot != leaf.startIndex else { return nil }
        let value = String(leaf[leaf.index(after: dot)...]).lowercased()
        return value.isEmpty ? nil : value
    }

    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    private static func trimmedBase(_ value: String) -> String {
        var result = value
        while result.first == "." { result.removeFirst() }
        return trimmedTrailing(result, characters: " .")
    }

    private static func trimmedTrailing(_ value: String, characters: String) -> String {
        var result = value
        while let last = result.last, characters.contains(last) { result.removeLast() }
        return result
    }

    private static func safeExtension(_ value: String) -> String? {
        guard (1...16).contains(value.count), value.unicodeScalars.allSatisfy({
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }) else { return nil }
        return value
    }

    private static func capped(_ value: String, bytes: Int) -> String {
        var result = ""
        var count = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard count + characterBytes <= bytes else { break }
            result.append(character)
            count += characterBytes
        }
        return result
    }
}
