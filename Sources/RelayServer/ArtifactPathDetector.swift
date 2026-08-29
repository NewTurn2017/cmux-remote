import Foundation

/// Extracts path-shaped tokens from untrusted visible terminal text.
struct ArtifactPathDetector: Sendable {
    private enum EscapeState {
        case text
        case escape
        case escapeIntermediate
        case csi
        case stringControl(allowsBEL: Bool)
        case stringControlEscape(allowsBEL: Bool)
    }

    /// Returns path candidates in display order after removing terminal controls.
    func paths(in terminalText: String) -> [String] {
        let visible = strippingTerminalControls(from: terminalText)
        var result: [String] = []
        var token = ""
        var quote: Unicode.Scalar?
        var escaping = false

        func appendToken() {
            defer { token.removeAll(keepingCapacity: true) }
            guard let candidate = normalizedCandidate(token) else { return }
            result.append(candidate)
        }

        for scalar in visible.unicodeScalars {
            if escaping {
                token.unicodeScalars.append(scalar)
                escaping = false
                continue
            }
            if scalar.value == 0x5C {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if scalar == activeQuote {
                    quote = nil
                } else {
                    token.unicodeScalars.append(scalar)
                }
                continue
            }
            if scalar.value == 0x22 || scalar.value == 0x27 {
                quote = scalar
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                appendToken()
            } else {
                token.unicodeScalars.append(scalar)
            }
        }
        if escaping { token.append("\\") }
        appendToken()
        return result
    }

    private func normalizedCandidate(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`([{<"))
        let trailing = CharacterSet(charactersIn: "`)]}>,;!?")
        while let scalar = candidate.unicodeScalars.last,
              trailing.contains(scalar) || scalar.value == 0x2E {
            candidate.unicodeScalars.removeLast()
        }
        if let markdown = candidate.range(of: "]("), markdown.upperBound < candidate.endIndex {
            candidate = String(candidate[markdown.upperBound...])
        }
        candidate = strippingCompilerLocation(from: candidate)

        if candidate.lowercased().hasPrefix("http://") || candidate.lowercased().hasPrefix("https://") {
            return nil
        }
        if candidate.hasPrefix("file://") {
            guard let url = URL(string: candidate), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            candidate = url.path
        }
        guard candidate.hasPrefix("/") || candidate.hasPrefix("./") || candidate.hasPrefix("../"),
              candidate != "/",
              !candidate.isEmpty,
              candidate.utf8.count <= 4_096,
              !candidate.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        return candidate
    }

    private func strippingCompilerLocation(from candidate: String) -> String {
        let scalars = candidate.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            guard scalars[index].value == 0x3A else {
                index = scalars.index(after: index)
                continue
            }
            var cursor = scalars.index(after: index)
            let digitStart = cursor
            while cursor < scalars.endIndex, (0x30...0x39).contains(scalars[cursor].value) {
                cursor = scalars.index(after: cursor)
            }
            guard cursor > digitStart else {
                index = scalars.index(after: index)
                continue
            }
            if cursor == scalars.endIndex || scalars[cursor].value == 0x3A {
                return String(candidate[..<index])
            }
            index = scalars.index(after: index)
        }
        return candidate
    }

    private func strippingTerminalControls(from text: String) -> String {
        var output = String.UnicodeScalarView()
        var state = EscapeState.text

        for scalar in text.unicodeScalars {
            switch state {
            case .text:
                switch scalar.value {
                case 0x1B: state = .escape
                case 0x9B: state = .csi
                case 0x9D: state = .stringControl(allowsBEL: true)
                case 0x90, 0x98, 0x9E, 0x9F: state = .stringControl(allowsBEL: false)
                case 0x9C: break
                default: output.append(scalar)
                }
            case .escape:
                switch scalar.value {
                case 0x5B: state = .csi
                case 0x5D: state = .stringControl(allowsBEL: true)
                case 0x50, 0x58, 0x5E, 0x5F: state = .stringControl(allowsBEL: false)
                case 0x20...0x2F: state = .escapeIntermediate
                case 0x30...0x7E: state = .text
                default:
                    output.append(scalar)
                    state = .text
                }
            case .escapeIntermediate:
                if !(0x20...0x2F).contains(scalar.value) { state = .text }
            case .csi:
                if (0x40...0x7E).contains(scalar.value) { state = .text }
            case .stringControl(let allowsBEL):
                if scalar.value == 0x9C || (allowsBEL && scalar.value == 0x07) {
                    state = .text
                } else if scalar.value == 0x1B {
                    state = .stringControlEscape(allowsBEL: allowsBEL)
                }
            case .stringControlEscape(let allowsBEL):
                if scalar.value == 0x5C || scalar.value == 0x9C || (allowsBEL && scalar.value == 0x07) {
                    state = .text
                } else if scalar.value != 0x1B {
                    state = .stringControl(allowsBEL: allowsBEL)
                }
            }
        }
        return String(output)
    }
}
