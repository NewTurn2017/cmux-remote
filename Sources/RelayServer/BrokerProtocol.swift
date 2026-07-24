import Foundation

/// Messages exchanged between the public broker and the Mac relay. The
/// iPhone still speaks the original cmux Remote protocol; only this outer
/// envelope is new.
public struct BrokerEnvelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case sessionOpen = "session.open"
        case sessionText = "session.text"
        case sessionClose = "session.close"
    }

    public var type: Kind
    public var sessionId: String
    public var deviceId: String?
    public var text: String?

    enum CodingKeys: String, CodingKey {
        case type, sessionId = "session_id", deviceId = "device_id", text
    }

    public init(type: Kind, sessionId: String, deviceId: String? = nil, text: String? = nil) {
        self.type = type
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.text = text
    }

    public static func open(sessionId: String, deviceId: String) -> Self {
        .init(type: .sessionOpen, sessionId: sessionId, deviceId: deviceId)
    }

    public static func text(sessionId: String, text: String) -> Self {
        .init(type: .sessionText, sessionId: sessionId, text: text)
    }

    public static func close(sessionId: String) -> Self {
        .init(type: .sessionClose, sessionId: sessionId)
    }
}
