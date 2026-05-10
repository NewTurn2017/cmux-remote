import Foundation
import CryptoKit

public enum ScreenHasher {
    /// Stable hash over the full screen state (rows + cursor). Used for the
    /// `screen.checksum` push frame: client and server must agree on this.
    public static func hash(_ screen: Screen) -> String {
        var hasher = SHA256()
        for row in screen.rows {
            hasher.update(data: Data(row.utf8))
            hasher.update(data: Data([0x0A]))
        }
        hasher.update(data: Data([0xFF]))
        var cursorBytes = withUnsafeBytes(of: screen.cursor.x.littleEndian) { Data($0) }
        cursorBytes.append(contentsOf: withUnsafeBytes(of: screen.cursor.y.littleEndian) { Array($0) })
        hasher.update(data: cursorBytes)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Per-row hash for DiffEngine row-change detection. Same algorithm.
    public static func rowHash(_ row: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(row.utf8))
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
