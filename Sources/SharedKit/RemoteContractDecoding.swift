import Foundation

extension KeyedDecodingContainer {
    /// Decodes a present value, reporting an absent or null key as missing and any other failure as invalid.
    ///
    /// Nested contract types throw their own ``RemoteProtocolError``, which passes through unchanged.
    func contractRequired<Value: Decodable>(_ type: Value.Type, _ key: Key, field: String) throws -> Value {
        guard let value = try contractOptional(type, key, field: field) else {
            throw RemoteProtocolError.missingField(field)
        }
        return value
    }

    /// Decodes a value that may be absent or null; any other failure is reported as invalid.
    func contractOptional<Value: Decodable>(_ type: Value.Type, _ key: Key, field: String) throws -> Value? {
        guard contains(key), !(try decodeNil(forKey: key)) else { return nil }
        do {
            return try decode(type, forKey: key)
        } catch let error as RemoteProtocolError {
            throw error
        } catch {
            throw RemoteProtocolError.invalidField(field)
        }
    }

    /// Decodes a required non-empty string within optional character and UTF-8 byte limits.
    func contractText(_ key: Key, field: String, maxCharacters: Int? = nil, maxUTF8Bytes: Int? = nil) throws -> String {
        guard let value = try contractOptionalText(key, field: field, maxCharacters: maxCharacters, maxUTF8Bytes: maxUTF8Bytes),
              !value.isEmpty
        else { throw RemoteProtocolError.missingField(field) }
        return value
    }

    /// Decodes an optional string within optional character and UTF-8 byte limits.
    func contractOptionalText(_ key: Key, field: String, maxCharacters: Int? = nil, maxUTF8Bytes: Int? = nil) throws -> String? {
        guard let value = try contractOptional(String.self, key, field: field) else { return nil }
        if let maxCharacters, value.count > maxCharacters { throw RemoteProtocolError.invalidField(field) }
        if let maxUTF8Bytes, value.utf8.count > maxUTF8Bytes { throw RemoteProtocolError.invalidField(field) }
        return value
    }

    /// Decodes an optional integer that must fall inside `range`.
    func contractOptionalInt(_ key: Key, field: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = try contractOptional(Int.self, key, field: field) else { return nil }
        guard range.contains(value) else { throw RemoteProtocolError.invalidField(field) }
        return value
    }
}
