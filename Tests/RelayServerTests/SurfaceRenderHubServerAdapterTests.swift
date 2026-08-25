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
