import Foundation

protocol WSClientConnectionFactory: Sendable {
    func makeConnection(
        url: URL,
        headers: [String: String],
        protocols: [String],
        onOpen: @escaping @Sendable () async -> Void,
        onClose: @escaping @Sendable (Int) async -> Void
    ) async -> any WSClientConnection
}
