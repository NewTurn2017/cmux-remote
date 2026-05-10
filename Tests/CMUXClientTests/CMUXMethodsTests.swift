import XCTest
import NIOCore
import NIOEmbedded
import SharedKit
@testable import CMUXClient

final class CMUXMethodsTests: XCTestCase {
    // MARK: - Translator unit tests
    //
    // The full CMUXClient + EmbeddedChannel round-trip suffers from a known
    // pre-existing thread-safety issue on baseline M2 (EmbeddedEventLoop
    // crossed by `async let`). M3 will replace EmbeddedChannel with
    // MultiThreadedEventLoopGroup in test fixtures. Until then, these tests
    // validate the translator boundary directly: feed cmux-shape JSON,
    // assert the translator yields the slim SharedKit model.

    /// Mirrors `docs/specs/cmux-payload-samples/workspace.list.json` and proves
    /// `CMUXWorkspaceListRaw` decodes the cmux v2 shape (with all the
    /// connection/proxy/remote noise) and translates to slim
    /// `SharedKit.Workspace` carrying only `id` / `name` / `index`.
    func testWorkspaceListRawSchemaDecodesAndTranslates() throws {
        let json = #"""
        {
          "window_ref": "window:1",
          "window_id": "W-1",
          "workspaces": [
            {"id":"WS-1","title":"frontend","index":0,"ref":"workspace:1","selected":true,"pinned":false,
             "current_directory":"/x","listening_ports":[],"description":null,"custom_color":null,
             "remote":{"state":"disconnected","detail":null,"active_terminal_sessions":0,"connected":false,
                       "daemon":{"capabilities":[],"detail":null,"state":"unavailable","name":null,
                                 "remote_path":null,"version":null},
                       "forwarded_ports":[],"transport":null,"has_ssh_options":false,
                       "has_identity_file":false,"heartbeat":{"count":0,"last_seen_at":null,"age_seconds":null},
                       "detected_ports":[],"local_proxy_port":null,
                       "proxy":{"schemes":["socks5","http_connect"],"error_code":null,"state":"unavailable",
                                "host":null,"url":null,"port":null},
                       "enabled":false,"destination":null,"conflicted_ports":[],"port":null}},
            {"id":"WS-2","title":"따능에이전트개발","index":1,"ref":"workspace:2","selected":false,"pinned":true,
             "current_directory":"/y","listening_ports":[],"description":null,"custom_color":null,
             "remote":{"state":"disconnected","detail":null,"active_terminal_sessions":0,"connected":false,
                       "daemon":{"capabilities":[],"detail":null,"state":"unavailable","name":null,
                                 "remote_path":null,"version":null},
                       "forwarded_ports":[],"transport":null,"has_ssh_options":false,
                       "has_identity_file":false,"heartbeat":{"count":0,"last_seen_at":null,"age_seconds":null},
                       "detected_ports":[],"local_proxy_port":null,
                       "proxy":{"schemes":[],"error_code":null,"state":"unavailable",
                                "host":null,"url":null,"port":null},
                       "enabled":false,"destination":null,"conflicted_ports":[],"port":null}}
          ]
        }
        """#
        let raw = try SharedKitJSON.snakeCaseDecoder.decode(CMUXWorkspaceListRaw.self,
                                                           from: Data(json.utf8))
        let workspaces = raw.workspaces.map { $0.toWorkspace() }

        XCTAssertEqual(workspaces.count, 2)
        XCTAssertEqual(workspaces[0].id, "WS-1")
        XCTAssertEqual(workspaces[0].name, "frontend")
        XCTAssertEqual(workspaces[0].index, 0)
        XCTAssertEqual(workspaces[1].name, "따능에이전트개발")  // Korean UTF-8 round-trip
        XCTAssertEqual(workspaces[1].index, 1)
    }

    /// Mirrors `docs/specs/cmux-payload-samples/surface.list.json`. Cmux nests
    /// surfaces under `surfaces[]` and includes pane/tmux fields the relay
    /// drops; the translator yields slim `SharedKit.Surface { id, title, index }`.
    func testSurfaceListRawSchemaDecodesAndTranslates() throws {
        let json = #"""
        {
          "workspace_ref":"workspace:1",
          "workspace_id":"WS-1",
          "window_ref":"window:1",
          "window_id":"W-1",
          "surfaces":[
            {"id":"SF-1","index":0,"focused":true,"pane_ref":"pane:9","tmux_start_command":null,
             "index_in_pane":0,"initial_command":null,"title":"shell","type":"terminal",
             "pane_id":"P-9","ref":"surface:9","selected_in_pane":true,
             "requested_working_directory":"/x"},
            {"id":"SF-2","index":1,"focused":false,"pane_ref":"pane:10","tmux_start_command":null,
             "index_in_pane":0,"initial_command":null,"title":"vim main.swift","type":"terminal",
             "pane_id":"P-10","ref":"surface:10","selected_in_pane":false,
             "requested_working_directory":"/x"}
          ]
        }
        """#
        let raw = try SharedKitJSON.snakeCaseDecoder.decode(CMUXSurfaceListRaw.self,
                                                           from: Data(json.utf8))
        let surfaces = raw.surfaces.map { $0.toSurface() }

        XCTAssertEqual(surfaces.count, 2)
        XCTAssertEqual(surfaces[0].id, "SF-1")
        XCTAssertEqual(surfaces[0].title, "shell")
        XCTAssertEqual(surfaces[0].index, 0)
        XCTAssertEqual(surfaces[1].title, "vim main.swift")
    }

    /// `surface.read_text` returns flat newline-joined `text` plus a base64
    /// mirror; the translator splits on `\n`, derives `cols` from the longest
    /// line, and stamps a stub cursor at `(0,0)` until cmux exposes cursor
    /// coords over RPC.
    func testSurfaceReadTextSynthesizesScreen() throws {
        let json = #"""
        {"workspace_id":"WS-1","surface_id":"SF-1","text":"hello\nworld!!\nfoo","base64":"aGVsbG8=",
         "workspace_ref":"workspace:1","window_ref":"window:1","window_id":"W-1","surface_ref":"surface:9"}
        """#
        let raw = try SharedKitJSON.snakeCaseDecoder.decode(CMUXReadTextRaw.self,
                                                            from: Data(json.utf8))
        let screen = raw.toScreen(rev: 7)

        XCTAssertEqual(screen.rev, 7)                          // caller-stamped
        XCTAssertEqual(screen.rows, ["hello", "world!!", "foo"])
        XCTAssertEqual(screen.cols, 7)                         // longest line = "world!!"
        XCTAssertEqual(screen.cursor, CursorPos(x: 0, y: 0))
    }

    /// `surface.read_text` with an empty buffer should produce a Screen with
    /// one empty row (split of "" by '\n' gives [""]) and cols=0. Guards
    /// against divide-by-zero / crash inside DiffEngine when first connecting
    /// before the terminal has rendered anything.
    func testSurfaceReadTextEmptyBuffer() throws {
        let json = #"""
        {"workspace_id":"WS-1","surface_id":"SF-1","text":"","base64":""}
        """#
        let raw = try SharedKitJSON.snakeCaseDecoder.decode(CMUXReadTextRaw.self,
                                                            from: Data(json.utf8))
        let screen = raw.toScreen(rev: 0)
        XCTAssertEqual(screen.rows, [""])
        XCTAssertEqual(screen.cols, 0)
    }
}
