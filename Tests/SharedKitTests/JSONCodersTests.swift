import Testing
import Foundation
@testable import SharedKit

@Suite("JSONCoders")
struct JSONCodersTests {
    @Test func deterministicEncoderProducesSortedKeys() throws {
        struct T: Codable { let z: Int; let a: Int }
        let data = try SharedKitJSON.deterministicEncoder.encode(T(z: 2, a: 1))
        let s = String(data: data, encoding: .utf8)!
        #expect(s == #"{"a":1,"z":2}"#)
    }

    @Test func snakeCaseEncoderConvertsCamel() throws {
        struct T: Codable { let surfaceId: String }
        let data = try SharedKitJSON.snakeCaseEncoder.encode(T(surfaceId: "x"))
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("surface_id"))
    }
}
