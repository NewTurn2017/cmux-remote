import Foundation

struct PreparedAttachment: Sendable {
    let ordinal: Int
    let filename: String
    let mimeType: String
    let bytes: Int64
    let sha256: String
    let stagedURL: URL
}
