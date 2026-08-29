import Foundation
import NIOCore
import SharedKit
import Testing
@testable import CMUXClient

@Suite("UnixSocketAuthenticationTests")
struct UnixSocketAuthenticationTests {
    @Test func productionUnixSocketPropagatesAuthenticationRejection() async throws {
        let fixture = try await MTELGCmuxFixture.makeUnixSocket(
            requestTimeout: .seconds(1)
        )
        do {
            async let authentication: Void = fixture.client.authenticate(password: "wrong-secret")
            let requestLine = try await fixture.awaitRequestLine()
            let request = try SharedKitJSON.snakeCaseDecoder.decode(
                RPCRequest.self,
                from: Data(requestLine.utf8)
            )
            #expect(request.method == "auth.login")
            #expect(request.params == .object([
                "password": .string("wrong-secret"),
            ]))

            let response = RPCResponse(
                id: request.id,
                ok: false,
                error: RPCError(code: "unauthorized", message: "invalid password")
            )
            let responseData = try SharedKitJSON.deterministicEncoder.encode(response)
            let responseLine = try #require(String(data: responseData, encoding: .utf8))
            try await fixture.sendToClient(line: responseLine)

            do {
                try await authentication
                Issue.record("authentication rejection unexpectedly succeeded")
            } catch CMUXClientError.rpc(let error) {
                #expect(error.code == "unauthorized")
                #expect(error.message == "invalid password")
            }
            await fixture.shutdown()
        } catch {
            await fixture.shutdown()
            throw error
        }
    }
}
