import Foundation

/// Runtime lookup for text that SwiftUI receives as a variable instead of a
/// localizable string literal, such as enum labels and formatted messages.
enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: .current, arguments: arguments)
    }
}
