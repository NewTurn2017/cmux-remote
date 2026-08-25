import Foundation
import Testing
import SharedKit
@testable import CMUXClient

struct RenderGridTestSupport {
    static let reset = "\u{1B}[0m"

    static func fixtureData() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "terminal-replay-34-styles",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    static func responseJSON(
        format: String = "cmux.render-grid.v1",
        columns: Int = 8,
        rows: Int = 2,
        cursorRow: Int = 1,
        cursorColumn: Int = 0,
        styles: String = #"[{"id":0,"foreground_source":"default","background_source":"default"}]"#,
        rowSpans: String = #"[{"row":0,"column":0,"style_id":0,"text":"x"}]"#,
        scrollbackRows: Int = 0,
        scrollbackSpans: String = "[]",
        terminalForeground: String = "#eaeaea",
        terminalBackground: String = "#101820"
    ) -> Data {
        Data(
            """
            {
              "text":"legacy",
              "render_grid":{
                "format":"\(format)",
                "surface_id":"surface-test",
                "state_seq":1,
                "render_epoch":"00000000-0000-4000-8000-000000000001",
                "render_revision":2,
                "columns":\(columns),
                "rows":\(rows),
                "cursor":{"row":\(cursorRow),"column":\(cursorColumn),"visible":true,"blinking":false,"style":0},
                "styles":\(styles),
                "row_spans":\(rowSpans),
                "scrollback_rows":\(scrollbackRows),
                "scrollback_spans":\(scrollbackSpans),
                "terminal_foreground":"\(terminalForeground)",
                "terminal_background":"\(terminalBackground)"
              }
            }
            """.utf8
        )
    }

    static func decode(_ data: Data) throws -> CMUXReadTextRaw {
        try SharedKitJSON.snakeCaseDecoder.decode(CMUXReadTextRaw.self, from: data)
    }

    static func visibleText(_ ansi: String) -> String {
        var result = ""
        var iterator = ansi.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard iterator.next() == "[" else { continue }
                while let code = iterator.next(), !(0x40...0x7E).contains(code.value) {}
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
