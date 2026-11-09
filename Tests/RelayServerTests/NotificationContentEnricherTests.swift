import Foundation
import XCTest
import SharedKit
@testable import RelayServer

final class NotificationContentEnricherTests: XCTestCase {
    private func makeEnricher(
        _ script: NotificationDispatchScript,
        logs: NotificationLogLines = NotificationLogLines(),
        timeout: Duration = .seconds(5)
    ) -> NotificationContentEnricher {
        NotificationContentEnricher(
            dispatch: { method, _ in try await script.call(method: method) },
            timeout: timeout,
            log: { logs.append($0) }
        )
    }

    private func payload(_ event: EventFrame) throws -> [String: JSONValue] {
        guard case .object(let payload) = event.payload else { throw NotificationFixture.ShapeError() }
        return payload
    }

    func testFillsRedactedCreatedFromNotificationList() async throws {
        let script = NotificationDispatchScript(answers: [.result(try NotificationFixture.listResult())])
        let enricher = makeEnricher(script)
        let original = try NotificationFixture.event("notification.created")

        let filled = await enricher.fill(original)

        let result = try payload(filled)
        let before = try payload(original)
        XCTAssertEqual(result["title"], .string("Claude Code"))
        XCTAssertEqual(result["subtitle"], .string("agent-lab"))
        XCTAssertEqual(result["body"], .string("Claude is waiting for your input"))
        XCTAssertEqual(result["tab_title"], .string("claude"))
        XCTAssertNil(result["redacted_fields"])
        for key in ["notification_id", "workspace_id", "surface_id", "replaced_notification_ids",
                    "is_read", "delivery", "title_length", "body_length"] {
            XCTAssertEqual(result[key], before[key], key)
        }
        XCTAssertEqual(filled.name, original.name)
        XCTAssertEqual(filled.category, original.category)
        let methods = await script.methods
        XCTAssertEqual(methods, ["notification.list"])
        let counts = await enricher.counts
        XCTAssertEqual(counts, .init(filled: 1, listCalls: 1))
    }

    func testListMissForwardsEventUnchangedAfterOneCall() async throws {
        let script = NotificationDispatchScript(answers: [.result(NotificationFixture.list(ids: ["N-9999"]))])
        let logs = NotificationLogLines()
        let enricher = makeEnricher(script, logs: logs)
        let original = try NotificationFixture.event("notification.created")

        let forwarded = await enricher.fill(original)

        XCTAssertEqual(forwarded, original)
        let methods = await script.methods
        XCTAssertEqual(methods.count, 1)
        let counts = await enricher.counts
        XCTAssertEqual(counts, .init(notFound: 1, listCalls: 1))
        XCTAssertEqual(logs.lines.count, 1)
        XCTAssertTrue(logs.lines[0].contains("not_found"))
    }

    func testFailuresForwardEventUnchangedAndLogOnlyTheCode() async throws {
        let cases: [(NotificationDispatchScript.Answer, String)] = [
            (.error(RPCError(code: "rate_limited", message: "slow down")), "code=rate_limited"),
            (.transportFailure, "code=unavailable"),
            (.result(.object([:])), "code=invalid_response"),
        ]
        for (answer, expectedCode) in cases {
            let logs = NotificationLogLines()
            let enricher = makeEnricher(NotificationDispatchScript(answers: [answer]), logs: logs)
            let original = try NotificationFixture.event("notification.created")

            let forwarded = await enricher.fill(original)

            XCTAssertEqual(forwarded, original, expectedCode)
            let counts = await enricher.counts
            XCTAssertEqual(counts.failed, 1, expectedCode)
            XCTAssertEqual(logs.lines.count, 1, expectedCode)
            XCTAssertTrue(logs.lines[0].contains("failed \(expectedCode)"), logs.lines[0])
        }
    }

    func testListThatOutlivesTheTimeoutForwardsEventUnchanged() async throws {
        let gate = NotificationGate()
        let script = NotificationDispatchScript(
            answers: [.result(try NotificationFixture.listResult())],
            gate: gate
        )
        let enricher = makeEnricher(script, timeout: .milliseconds(50))
        let original = try NotificationFixture.event("notification.created")

        let forwarded = await enricher.fill(original)
        await gate.open()

        XCTAssertEqual(forwarded, original)
        let counts = await enricher.counts
        XCTAssertEqual(counts.timedOut, 1)
    }

    func testConsecutiveEventsShareOneListResult() async throws {
        let script = NotificationDispatchScript(answers: [.result(NotificationFixture.list(ids: ["A", "B"]))])
        let enricher = makeEnricher(script)

        let first = await enricher.fill(try NotificationFixture.created(id: "A"))
        let second = await enricher.fill(try NotificationFixture.created(id: "B"))

        XCTAssertEqual(try payload(first)["title"], .string("title A"))
        XCTAssertEqual(try payload(second)["title"], .string("title B"))
        let methods = await script.methods
        XCTAssertEqual(methods.count, 1)
    }

    func testEventArrivingDuringRunningListUsesItsResult() async throws {
        let gate = NotificationGate()
        let script = NotificationDispatchScript(
            answers: [.result(NotificationFixture.list(ids: ["A", "B"]))],
            gate: gate
        )
        let enricher = makeEnricher(script)
        let eventA = try NotificationFixture.created(id: "A")
        let eventB = try NotificationFixture.created(id: "B")

        let first = Task { await enricher.fill(eventA) }
        await awaitBounded("first list call started") { await script.waitUntilCalled(times: 1) }
        let second = Task { await enricher.fill(eventB) }
        await awaitBounded("both events wait on the list") { await enricher.waitUntilWaiting(count: 2) }
        await gate.open()

        let filledA = await first.value
        let filledB = await second.value
        XCTAssertEqual(try payload(filledA)["title"], .string("title A"))
        XCTAssertEqual(try payload(filledB)["title"], .string("title B"))
        let methods = await script.methods
        XCTAssertEqual(methods.count, 1)
    }

    func testMissInAnEarlierRunningListEarnsOneFreshCall() async throws {
        let gate = NotificationGate()
        let script = NotificationDispatchScript(
            answers: [
                .result(NotificationFixture.list(ids: ["A"])),
                .result(NotificationFixture.list(ids: ["A", "B"])),
            ],
            gate: gate
        )
        let enricher = makeEnricher(script)
        let eventA = try NotificationFixture.created(id: "A")
        let eventB = try NotificationFixture.created(id: "B")

        let first = Task { await enricher.fill(eventA) }
        await awaitBounded("first list call started") { await script.waitUntilCalled(times: 1) }
        let second = Task { await enricher.fill(eventB) }
        await awaitBounded("both events wait on the list") { await enricher.waitUntilWaiting(count: 2) }
        await gate.open()

        _ = await first.value
        let filledB = await second.value
        XCTAssertEqual(try payload(filledB)["title"], .string("title B"))
        let methods = await script.methods
        XCTAssertEqual(methods.count, 2)
    }

    func testOtherEventsPassThroughWithoutCallingCmux() async throws {
        let script = NotificationDispatchScript(answers: [.result(try NotificationFixture.listResult())])
        let enricher = makeEnricher(script)
        let read = try NotificationFixture.event("notification.read")
        let workspace = EventFrame(category: .workspace, name: "workspace.updated", payload: .object([:]))

        let forwardedRead = await enricher.fill(read)
        let forwardedWorkspace = await enricher.fill(workspace)

        XCTAssertEqual(forwardedRead, read)
        XCTAssertEqual(forwardedWorkspace, workspace)
        let methods = await script.methods
        XCTAssertTrue(methods.isEmpty)
    }

    func testLongContentIsCapped() async throws {
        let list: JSONValue = .object(["notifications": .array([.object([
            "id": .string("N-0001"),
            "title": .string(String(repeating: "t", count: 600)),
            "body": .string(String(repeating: "본", count: 5_000)),
            "tab_title": .string(String(repeating: "x", count: 300)),
        ])])])
        let enricher = makeEnricher(NotificationDispatchScript(answers: [.result(list)]))

        let filled = try payload(await enricher.fill(try NotificationFixture.event("notification.created")))

        guard case .string(let title)? = filled["title"], case .string(let body)? = filled["body"],
              case .string(let tabTitle)? = filled["tab_title"]
        else { return XCTFail("filled strings expected") }
        XCTAssertEqual(title.count, NotificationContentEnricher.titleLimit)
        XCTAssertEqual(body.count, NotificationContentEnricher.bodyLimit)
        XCTAssertEqual(tabTitle.count, NotificationContentEnricher.tabTitleLimit)
        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertEqual(filled["redacted_fields"], .array([.string("subtitle")]))
    }

    func testLogsNeverContainNotificationContentOrIds() async throws {
        let logs = NotificationLogLines()
        let script = NotificationDispatchScript(answers: [
            .result(try NotificationFixture.listResult()),
            .result(NotificationFixture.list(ids: [])),
            .error(RPCError(code: "rate_limited", message: "Claude Code agent-lab")),
        ])
        let enricher = makeEnricher(script, logs: logs)

        _ = await enricher.fill(try NotificationFixture.event("notification.created"))
        _ = await enricher.fill(try NotificationFixture.created(id: "WS-AAAA"))
        _ = await enricher.fill(try NotificationFixture.created(id: "SF-1111"))

        XCTAssertEqual(logs.lines.count, 3)
        for line in logs.lines {
            for sensitive in NotificationFixture.stringsThatMustNotBeLogged {
                XCTAssertFalse(line.contains(sensitive), "log line leaks \(sensitive)")
            }
        }
    }
}
