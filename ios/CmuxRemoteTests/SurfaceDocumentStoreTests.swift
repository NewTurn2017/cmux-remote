import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@Suite("SurfaceDocumentStoreTests", .serialized, .timeLimit(.minutes(1)))
struct SurfaceDocumentStoreTests {
    private let open = RemoteRPCMethod.surfaceDocumentOpen.rawValue
    private let fetch = RemoteRPCMethod.artifactFetch.rawValue

    @Test
    func testMissingCapabilityKeepsPlaceholderCardAndSendsNoRPC() async {
        let markdown = Surface(id: "md", title: "README.md", index: 0, type: "markdown")
        let browser = Surface(id: "web", title: "localhost", index: 1, type: "browser")
        let terminal = Surface(id: "sh", title: "shell", index: 2, type: "terminal")

        #expect(!SurfaceSelectionPolicy.showsDocument(for: markdown, documentsEnabled: false))
        #expect(SurfaceSelectionPolicy.showsDocument(for: markdown, documentsEnabled: true))
        #expect(!SurfaceSelectionPolicy.showsDocument(for: browser, documentsEnabled: true))
        #expect(!SurfaceSelectionPolicy.showsDocument(for: terminal, documentsEnabled: true))
        #expect(SurfaceSelectionPolicy.route(for: markdown, reportedNotTerminal: []) == .placeholder)

        let rpc = DocumentRPCStub()
        _ = await MainActor.run { SurfaceDocumentStore(rpc: rpc) }
        #expect(await rpc.callCount(method: open) == 0)
    }

    @Test @MainActor
    func testOpenFetchesAndRendersSingleArtifact() async throws {
        let rpc = DocumentRPCStub()
        let bytes = Data("# Title\n\nBody text\n".utf8)
        let artifact = DocumentFixtures.artifact(bytes: bytes.count)
        await rpc.enqueue(.response(try DocumentFixtures.openResponse([artifact])), for: open)
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(offset: 0, total: bytes.count, data: bytes, eof: true)), for: fetch)
        let store = SurfaceDocumentStore(rpc: rpc)

        await store.open(workspaceID: "ws", surfaceID: "md", isConnected: true)

        guard case .loaded(let rendered) = store.state, case .markdown(let blocks) = rendered.body else {
            Issue.record("Expected loaded markdown, got \(store.state)")
            return
        }
        #expect(rendered.document.text == String(decoding: bytes, as: UTF8.self))
        #expect(blocks.first.map { block -> Bool in
            if case .heading(1, let text) = block.kind { return String(text.characters) == "Title" }
            return false
        } == true)
        #expect(store.surfaceID == "md")
        #expect(await rpc.params(method: open) == [.object(["workspace_id": .string("ws"), "surface_id": .string("md")])])
    }

    @Test @MainActor
    func testRefreshReopensAndReplacesRevision() async throws {
        let rpc = DocumentRPCStub()
        let first = Data("# One\n".utf8)
        let second = Data("# Two\n".utf8)
        let r1 = DocumentFixtures.artifact(id: "doc-1", bytes: first.count, revision: "r1")
        let r2 = DocumentFixtures.artifact(id: "doc-2", bytes: second.count, revision: "r2")
        await rpc.enqueue(.response(try DocumentFixtures.openResponse([r1])), for: open)
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(artifactID: "doc-1", offset: 0, total: first.count, revision: "r1", data: first, eof: true)), for: fetch)
        await rpc.enqueue(.response(try DocumentFixtures.openResponse([r2], generation: 2)), for: open)
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(artifactID: "doc-2", offset: 0, total: second.count, revision: "r2", data: second, eof: true)), for: fetch)
        let store = SurfaceDocumentStore(rpc: rpc)

        await store.open(workspaceID: "ws", surfaceID: "md", isConnected: true)
        await store.open(workspaceID: "ws", surfaceID: "md", isConnected: true)

        guard case .loaded(let rendered) = store.state else {
            Issue.record("Expected loaded state, got \(store.state)")
            return
        }
        #expect(rendered.document.revision == "r2")
        #expect(rendered.document.text == "# Two\n")
        #expect(!store.isRefreshing)
        #expect(await rpc.callCount(method: open) == 2)
    }

    @Test(arguments: [
        ("surface_not_document", DocumentLoadFailure.notDocument),
        ("not_found", DocumentLoadFailure.notFound),
        ("size_limit_exceeded", DocumentLoadFailure.tooLarge),
        ("unsupported_media", DocumentLoadFailure.notDocument),
        ("internal_error", DocumentLoadFailure.generic),
    ])
    @MainActor
    func testOpenErrorCodeMapsToFailureState(code: String, failure: DocumentLoadFailure) async {
        let rpc = DocumentRPCStub()
        await rpc.enqueue(.response(DocumentFixtures.error(code)), for: open)
        let store = SurfaceDocumentStore(rpc: rpc)

        await store.open(workspaceID: "ws", surfaceID: "md", isConnected: true)

        #expect(store.state == .failed(failure))
        #expect(await rpc.callCount(method: fetch) == 0)
    }

    @Test @MainActor
    func testFileChangedDuringFetchState() async throws {
        let rpc = DocumentRPCStub()
        await rpc.enqueue(.response(try DocumentFixtures.openResponse([DocumentFixtures.artifact(bytes: 10)])), for: open)
        await rpc.enqueue(.response(DocumentFixtures.error("file_changed")), for: fetch)
        let store = SurfaceDocumentStore(rpc: rpc)

        await store.open(workspaceID: "ws", surfaceID: "md", isConnected: true)

        #expect(store.state == .failed(.fileChanged))
    }

    @Test @MainActor
    func testDisconnectedStateSendsNoRPC() async {
        let rpc = DocumentRPCStub()
        let store = SurfaceDocumentStore(rpc: rpc)

        await store.open(workspaceID: "ws", surfaceID: "md", isConnected: false)

        #expect(store.state == .failed(.disconnected))
        #expect(await rpc.callCount(method: open) == 0)
    }

    @Test @MainActor
    func testMethodNotFoundFallsBackToCard() async {
        let rpc = DocumentRPCStub()
        await rpc.enqueue(.response(DocumentFixtures.error("method_not_found")), for: open)
        let store = SurfaceDocumentStore(rpc: rpc)

        await store.open(workspaceID: "ws", surfaceID: "md", isConnected: true)

        #expect(store.state == .unsupported)
    }

    @Test @MainActor
    func testRejectsOpenResultWithoutExactlyOneArtifact() async throws {
        let rpc = DocumentRPCStub()
        let a = DocumentFixtures.artifact(id: "a", bytes: 1)
        let b = DocumentFixtures.artifact(id: "b", bytes: 1)
        await rpc.enqueue(.response(try DocumentFixtures.openResponse([a, b])), for: open)
        let store = SurfaceDocumentStore(rpc: rpc)

        await store.open(workspaceID: "ws", surfaceID: "md", isConnected: true)

        #expect(store.state == .failed(.generic))
        #expect(await rpc.callCount(method: fetch) == 0)
    }

    @Test @MainActor
    func testStaleResultAfterSurfaceSwitchIsDiscarded() async throws {
        let rpc = DocumentRPCStub()
        let bytes = Data("# Old\n".utf8)
        await rpc.enqueue(.gate("old-open"), for: open)
        await rpc.enqueue(.response(DocumentFixtures.error("not_found")), for: open)
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(offset: 0, total: bytes.count, data: bytes, eof: true)), for: fetch)
        let store = SurfaceDocumentStore(rpc: rpc)

        let oldOpen = Task { await store.open(workspaceID: "ws", surfaceID: "old", isConnected: true) }
        await rpc.waitUntilReached("old-open")
        await store.open(workspaceID: "ws", surfaceID: "new", isConnected: true)
        #expect(store.state == .failed(.notFound))

        await rpc.release("old-open", with: try DocumentFixtures.openResponse([DocumentFixtures.artifact(bytes: bytes.count)]))
        await oldOpen.value

        #expect(store.surfaceID == "new")
        #expect(store.state == .failed(.notFound))
    }

    @Test @MainActor
    func testResetDropsLoadedDocument() async throws {
        let rpc = DocumentRPCStub()
        let bytes = Data("text".utf8)
        await rpc.enqueue(.response(try DocumentFixtures.openResponse([DocumentFixtures.artifact(bytes: bytes.count)])), for: open)
        await rpc.enqueue(.response(DocumentFixtures.fetchResponse(offset: 0, total: bytes.count, data: bytes, eof: true)), for: fetch)
        let store = SurfaceDocumentStore(rpc: rpc)
        await store.open(workspaceID: "ws", surfaceID: "md", isConnected: true)

        store.reset()

        #expect(store.state == .idle)
        #expect(store.surfaceID == nil)
    }
}
