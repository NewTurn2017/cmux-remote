import Foundation
import SharedKit

public protocol RPCTransport: Sendable {
    func send(text: String) async
    func close() async
}

public protocol RPCDispatch: Sendable {
    func call(method: String, params: JSONValue) async throws -> RPCResponse
}

public actor RPCClient: RPCDispatch {
    private let transport: any RPCTransport
    private var pending: [String: CheckedContinuation<RPCResponse, Error>] = [:]
    private var pushHandler: (@Sendable (PushFrame) -> Void)?
    private let timeoutNanoseconds: UInt64

    public init(transport: any RPCTransport, timeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.transport = transport
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func onPush(_ handler: @escaping @Sendable (PushFrame) -> Void) {
        pushHandler = handler
    }

    @discardableResult
    public func call(method: String, params: JSONValue) async throws -> RPCResponse {
        let id = UUID().uuidString
        let request = RPCRequest(id: id, method: method, params: params)
        let data = try SharedKitJSON.deterministicEncoder.encode(request)
        guard let text = String(data: data, encoding: .utf8) else { throw RPCClientError.encoding }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { await transport.send(text: text) }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.failPending(id: id, error: RPCClientError.timeout)
            }
        }
    }

    public func handleIncoming(text: String) {
        let data = Data(text.utf8)
        if let response = try? JSONDecoder().decode(RPCResponse.self, from: data),
           let continuation = pending.removeValue(forKey: response.id)
        {
            continuation.resume(returning: response)
            return
        }
        if let push = try? JSONDecoder().decode(PushFrame.self, from: data) {
            pushHandler?(push)
        }
    }

    public func failPending(id: String, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    public func failAllPending(_ error: Error = RPCClientError.closed) {
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    public func close() async {
        failAllPending(RPCClientError.closed)
        await transport.close()
    }
}

public enum RPCClientError: Error, Equatable {
    case encoding
    case timeout
    case closed
}

extension WSClient: RPCTransport {}
