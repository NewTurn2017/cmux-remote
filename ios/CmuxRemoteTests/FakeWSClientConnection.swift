import Foundation
@testable import CmuxRemote

actor FakeWSClientConnection: WSClientConnection {
    private let onOpen: @Sendable () async -> Void
    private let onClose: @Sendable (Int) async -> Void
    private let sendStream: AsyncStream<String>
    private let sendContinuation: AsyncStream<String>.Continuation
    private let receiveProbe: WSClientReceiveProbe
    private var receiveContinuation: CheckedContinuation<String?, Error>?
    private var isCancelled = false
    private var resumeCount = 0
    private var sendErrorsRemaining = 0
    private var sentTexts: [String] = []

    init(
        onOpen: @escaping @Sendable () async -> Void,
        onClose: @escaping @Sendable (Int) async -> Void,
        receiveProbe: WSClientReceiveProbe
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.receiveProbe = receiveProbe
        (sendStream, sendContinuation) = AsyncStream.makeStream(of: String.self)
    }

    func resume() {
        resumeCount += 1
    }

    func send(text: String) throws {
        guard !isCancelled else { throw CancellationError() }
        if sendErrorsRemaining > 0 {
            sendErrorsRemaining -= 1
            throw CancellationError()
        }
        sentTexts.append(text)
        sendContinuation.yield(text)
    }

    func receiveText() async throws -> String? {
        guard !isCancelled else { throw CancellationError() }
        await receiveProbe.started()
        guard !isCancelled else {
            await receiveProbe.ended()
            throw CancellationError()
        }
        do {
            let text = try await withCheckedThrowingContinuation { continuation in
                receiveContinuation = continuation
            }
            await receiveProbe.ended()
            return text
        } catch {
            await receiveProbe.ended()
            throw error
        }
    }

    func closeCode() -> Int {
        1000
    }

    func cancel() {
        isCancelled = true
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
    }

    func failNextSend() {
        sendErrorsRemaining += 1
    }

    func emitOpen() async {
        await onOpen()
    }

    func emitClose(code: Int) async {
        await onClose(code)
    }

    func sends() -> AsyncStream<String> {
        sendStream
    }

    func observedResumeCount() -> Int {
        resumeCount
    }

    func observedSentTexts() -> [String] {
        sentTexts
    }
}
