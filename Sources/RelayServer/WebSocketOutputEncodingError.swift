/// Reports an impossible UTF-8 conversion after deterministic JSON encoding.
enum WebSocketOutputEncodingError: Error {
    case invalidUTF8
    case missingStreamIdentity
}
