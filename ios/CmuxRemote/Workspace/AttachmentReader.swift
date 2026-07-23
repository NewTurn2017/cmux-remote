import Foundation

/// Reads a picked document's bytes under a hard memory ceiling. Plain Foundation
/// file IO with no SwiftUI, so it is unit-testable without a device or simulator.
enum AttachmentReader {
    /// Reads `url` and returns its bytes, or `nil` when the file holds more than
    /// `limit` bytes. Never buffers more than `limit + 1`, so a file whose size
    /// the provider under-reports — or does not report at all — still cannot pull
    /// an unbounded amount into memory.
    static func readBounded(from url: URL, limit: Int) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        // read(upToCount:) is allowed to return a short chunk, so keep going
        // until we hold limit + 1 bytes (one over is proof it's too big) or the
        // file ends.
        while data.count <= limit {
            let remaining = limit + 1 - data.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data.count > limit ? nil : data
    }
}
