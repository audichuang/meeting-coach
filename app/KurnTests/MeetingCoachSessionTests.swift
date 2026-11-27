import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// Answers every judge call with `emit` and every card call with a fixed card.
private struct ScriptedCoachLLM: CoachLLM {
    func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult {
        let name = tools[0].name
        let args: String
        switch name {
        case "judge": args = #"{"decision":"emit","reason":"有分歧"}"#
        case "emit_wrapup": args = #"{"common_goal":"g","disagreements":"d","open_questions":"o","next_steps":"n","spoken_text":"收尾"}"#
        default: args = #"{"short_text":"要不要先確認口徑？","reason":"數字沒對齊","evidence_start":999,"evidence_end":1000,"category":"clarify"}"#
        }
        return CoachCallResult(calls: [CoachToolCall(name: name, arguments: Data(args.utf8))],
                               usage: CoachTokenUsage(input: 1_000, cached: 0, output: 100))
    }
}

@MainActor
struct MeetingCoachSessionTests {
    private final class Clock { var now: TimeInterval = 0 }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func throttledCandidatesArePersistedAsSuppressedAndAskBypassesTheGate() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let clock = Clock()
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, apiKey: "test"),
            llm: ScriptedCoachLLM(), elapsed: { clock.now }
        )
        let recordingID = UUID()
        coach.begin(recordingID: recordingID)

        // Question at 60 s: shown? No — the opening 120 s is quiet, so it is suppressed.
        clock.now = 61
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 40, end: 60, text: "这个口径对吗？", arrivedAt: 60.5)))
        await waitUntil { coach.ledgers.count == 1 && coach.ledgers[0].events.count == 2 }
        #expect(coach.segments.first?.text == "這個口徑對嗎？")
        #expect(coach.ledgers[0].events.last?.kind == .suppressed(reason: "opening"))
        #expect(coach.currentCard == nil)
        // The app, not the model, sets the evidence span from the triggering segment.
        #expect(coach.ledgers[0].candidate.evidence.first?.start == 40)
        #expect(coach.ledgers[0].candidate.evidence.first?.recordingID == recordingID)

        clock.now = 150
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 130, end: 150, text: "志明你覺得呢", arrivedAt: 150.5)))
        await waitUntil { coach.currentCard != nil }
        #expect(coach.currentCard?.events.last?.kind == .shown)

        clock.now = 170   // 20 s later: cooldown suppresses the automatic card...
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 150, end: 170, text: "要不要延期？", arrivedAt: 170.5)))
        await waitUntil { coach.ledgers.count == 3 && coach.ledgers[2].events.count == 2 }
        #expect(coach.ledgers[2].events.last?.kind == .suppressed(reason: "minimum_gap"))

        clock.now = 175   // ...but「我該說什麼」is not gated.
        await coach.askForCard()
        #expect(coach.ledgers.count == 4)
        #expect(coach.currentCard?.candidate.version.policy == "ask")
        coach.expandCurrentCard()
        coach.feedbackOnCurrentCard(useful: true)
        coach.dismissCurrentCard()
        #expect(coach.ledgers[3].events.map(\.kind) == [.created, .shown, .expanded, .feedback(value: "useful"), .dismissed])

        await coach.finish(at: 180)
        let record = try #require(try context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(record.ledgers.count == 4)
        #expect(record.segments.count == 3)
        #expect(record.triggerLog.count == 3)
        #expect(record.costUSD > 0)
        #expect(meeting.coachRecords.count == 1)
    }

    @Test func discardingTheRecordingDeletesItsCoachRecord() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "我", budgetUSD: 10, apiKey: "test"),
            llm: ScriptedCoachLLM(), elapsed: { 0 }
        )
        coach.begin(recordingID: UUID())
        await coach.finish(at: 1, discarding: true)
        #expect(try context.fetch(FetchDescriptor<CoachRecord>()).isEmpty)
    }

    @Test func nameMatcherAcceptsHomophones() {
        let matches = ChineseText.nameMatcher(for: "志明")
        #expect(matches("致明你先講"))
        #expect(matches("那智明呢"))
        #expect(!matches("說明一下"))
        #expect(ChineseText.traditional("向量数据库在尖峰时间") == "向量數據庫在尖峰時間")
    }
}
