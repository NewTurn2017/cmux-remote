import SharedKit
import Testing
@testable import CmuxRemote

@Suite("FeedReplyPolicyTests")
struct FeedReplyPolicyTests {
    // MARK: buttons and modes

    @Test
    func testPermissionButtonsFollowAvailableModes() {
        #expect(FeedReplyPolicy.buttons(for: FeedFixtures.permission()) == [.allowOnce, .allowAlways, .deny])
        #expect(FeedReplyPolicy.buttons(for: FeedFixtures.permission(availableModes: ["once", "deny"])) == [.allowOnce, .deny])
        #expect(FeedReplyPolicy.buttons(for: FeedFixtures.permission(availableModes: nil)) == [.allowOnce, .allowAlways, .deny])
        #expect(FeedReplyPolicy.buttons(for: FeedFixtures.question()).isEmpty)
    }

    @Test
    func testPlanApproveUsesDefaultModeOrManual() {
        let manual = FeedFixtures.plan(defaultMode: "manual")
        #expect(FeedReplyButton.approve.mode(for: manual) == "manual")
        #expect(FeedReplyPolicy.buttons(for: manual) == [.approve, .autoApprove, .reject])

        #expect(FeedReplyButton.approve.mode(for: FeedFixtures.plan(defaultMode: nil)) == "manual")
        #expect(FeedReplyButton.approve.mode(for: FeedFixtures.plan(defaultMode: "deny")) == "manual")

        let autoAccept = FeedFixtures.plan(defaultMode: "autoAccept")
        #expect(FeedReplyButton.approve.mode(for: autoAccept) == "autoAccept")
        #expect(FeedReplyPolicy.buttons(for: autoAccept) == [.approve, .reject])
        #expect(FeedReplyButton.approve.requiresConfirmation(for: autoAccept))

        let manualOnly = FeedFixtures.plan(defaultMode: "manual", availableModes: ["manual", "deny"])
        #expect(FeedReplyPolicy.buttons(for: manualOnly) == [.approve, .reject])
    }

    @Test
    func testOnlyBroadGrantsRequireConfirmation() {
        let permission = FeedFixtures.permission()
        let plan = FeedFixtures.plan()
        #expect(FeedReplyButton.allowAlways.requiresConfirmation(for: permission))
        #expect(FeedReplyButton.autoApprove.requiresConfirmation(for: plan))
        #expect(!FeedReplyButton.allowOnce.requiresConfirmation(for: permission))
        #expect(!FeedReplyButton.deny.requiresConfirmation(for: permission))
        #expect(!FeedReplyButton.approve.requiresConfirmation(for: plan))
        #expect(!FeedReplyButton.reject.requiresConfirmation(for: plan))
    }

    // MARK: selections rules

    @Test
    func testSingleQuestionSingleSelectSendsExactlyOneLabel() {
        var draft = FeedQuestionDraft(questions: [FeedFixtures.singleSelect()])
        #expect(draft.outcome == .incomplete)
        draft.toggle(question: 0, option: 0)
        draft.toggle(question: 0, option: 2)
        #expect(draft.outcome == .ready(selections: ["C"]))
        draft.toggle(question: 0, option: 2)
        #expect(draft.outcome == .incomplete)
    }

    @Test
    func testSingleQuestionMultiSelectKeepsOptionOrderWithoutDuplicates() {
        var draft = FeedQuestionDraft(questions: [FeedFixtures.multiSelect(labels: ["A", "B", "A", "C"])])
        #expect(draft.outcome == .incomplete)
        draft.toggle(question: 0, option: 3)
        draft.toggle(question: 0, option: 0)
        draft.toggle(question: 0, option: 2)
        #expect(draft.outcome == .ready(selections: ["A", "C"]))
        draft.toggle(question: 0, option: 0)
        draft.toggle(question: 0, option: 2)
        #expect(draft.outcome == .ready(selections: ["C"]))
    }

    @Test
    func testSeveralSingleSelectQuestionsSendOneLabelEachInQuestionOrder() {
        var draft = FeedQuestionDraft(questions: [
            FeedFixtures.singleSelect("q1", labels: ["A", "B"]),
            FeedFixtures.singleSelect("q2", labels: ["X", "Y"]),
        ])
        draft.toggle(question: 1, option: 0)
        #expect(draft.outcome == .incomplete)
        draft.toggle(question: 0, option: 1)
        #expect(draft.outcome == .ready(selections: ["B", "X"]))
    }

    @Test
    func testSeveralQuestionsWithMultiSelectOrNoOptionsAnswerOnMac() {
        let withMulti = FeedQuestionDraft(questions: [FeedFixtures.singleSelect("q1"), FeedFixtures.multiSelect("q2")])
        #expect(withMulti.requiresMac)
        #expect(withMulti.outcome == .answerOnMac)

        let withoutOptions = FeedQuestionDraft(questions: [
            FeedFixtures.singleSelect("q1"),
            FeedQuestion(id: "q2", prompt: "Free text", multiSelect: false, options: []),
        ])
        #expect(withoutOptions.outcome == .answerOnMac)

        #expect(FeedQuestionDraft(questions: []).outcome == .answerOnMac)
    }

    @Test
    func testSingleQuestionWithoutOptionsSendsEmptySelections() {
        let draft = FeedQuestionDraft(questions: [FeedQuestion(id: "q1", prompt: "Continue?", multiSelect: false, options: [])])
        #expect(draft.outcome == .ready(selections: []))
    }
}
