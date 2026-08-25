import Foundation
import Testing
import SharedKit
@testable import RelayServer

@Suite("SurfaceRenderHubServerAdapterTests")
struct SurfaceRenderHubServerAdapterTests {
    @Test(arguments: [1, 15, 120])
    func clientSubscribeFpsRemainsIgnored(_ requestedFps: Int) async {
        let machine = WSProtocolMachine(cmux: SurfaceRenderHubNoOpFacade())
        _ = await machine.processText(
            #"{"deviceId":"device","appVersion":"1","protocolVersion":1}"#
        )

        let actions = await machine.processText(
            #"{"id":"subscribe","method":"surface.subscribe","params":{"workspace_id":"workspace","surface_id":"surface","fps":\#(requestedFps),"lines":120}}"#
        )

        #expect(actions == [
            .subscribe(
                responseId: "subscribe",
                workspaceId: "workspace",
                surfaceId: "surface",
                lines: 120
            ),
        ])
    }

    @Test func surfaceReadTextBecomesHubBackedFullRequest() async {
        let facade = SurfaceRenderHubNoOpFacade()
        let machine = WSProtocolMachine(cmux: facade)
        _ = await machine.processText(
            #"{"deviceId":"device","appVersion":"1","protocolVersion":1}"#
        )

        let actions = await machine.processText(
            #"{"id":"recover","method":"surface.read_text","params":{"workspace_id":"workspace","surface_id":"surface","lines":120}}"#
        )

        #expect(actions == [
            .requestFull(responseId: "recover", surfaceId: "surface"),
        ])
    }

    @Test func malformedSurfaceReadTextReturnsEstablishedRPCError() async {
        let machine = WSProtocolMachine(cmux: SurfaceRenderHubNoOpFacade())
        _ = await machine.processText(
            #"{"deviceId":"device","appVersion":"1","protocolVersion":1}"#
        )

        let actions = await machine.processText(
            #"{"id":"recover","method":"surface.read_text","params":{"workspace_id":"workspace"}}"#
        )

        guard case .sendText(let text)? = actions.first else {
            Issue.record("malformed recovery request must return an RPC response")
            return
        }
        let response = try? JSONDecoder().decode(RPCResponse.self, from: Data(text.utf8))
        #expect(response?.id == "recover")
        #expect(response?.error?.code == "invalid_params")
    }

    @Test func successfulInputRequestsActiveCadenceWake() async {
        let machine = WSProtocolMachine(cmux: SurfaceRenderHubNoOpFacade())
        _ = await machine.processText(
            #"{"deviceId":"device","appVersion":"1","protocolVersion":1}"#
        )

        let actions = await machine.processText(
            #"{"id":"input","method":"surface.send_text","params":{"workspace_id":"workspace","surface_id":"surface","text":"ls"}}"#
        )

        #expect(actions.count == 2)
        #expect(actions.last == .noteUserInput(surfaceId: "surface"))
    }
}
