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

/// Fails every call the way the Worker refuses it.
private struct RefusingCoachLLM: CoachLLM {
    let status: Int
    func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult {
        throw AppError.apiError(statusCode: status, message: "refused")
    }
}

/// Holds the first judge call so a test can cancel mid-flight and later deliver a late reply.
private final class SlowJudgeCoachLLM: CoachLLM, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var judgeGate: CheckedContinuation<Void, Never>?
    private var judgeReleased = false

    var calls: [String] { lock.withLock { recordedCalls } }

    func releaseJudge() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            judgeReleased = true
            let current = judgeGate
            judgeGate = nil
            return current
        }
        continuation?.resume()
    }

    func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult {
        let name = tools[0].name
        lock.withLock { recordedCalls.append(name) }
        if name == "judge" {
            // Wait until released (with a short safety timeout so a buggy caller awaiting it won't hang).
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withCheckedContinuation { continuation in
                        let alreadyReleased = self.lock.withLock { () -> Bool in
                            if self.judgeReleased { return true }
                            self.judgeGate = continuation
                            return false
                        }
                        if alreadyReleased { continuation.resume() }
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(300))
                    self.releaseJudge()
                }
                await group.next()
                group.cancelAll()
            }
            let args = #"{"decision":"emit","reason":"分歧"}"#
            return CoachCallResult(calls: [CoachToolCall(name: name, arguments: Data(args.utf8))],
                                   usage: CoachTokenUsage(input: 1_000, cached: 0, output: 100))
        }
        let args = #"{"short_text":"先對齊目標？","reason":"目標不同","evidence_start":0,"evidence_end":1,"category":"clarify"}"#
        return CoachCallResult(calls: [CoachToolCall(name: name, arguments: Data(args.utf8))],
                               usage: CoachTokenUsage(input: 1_000, cached: 0, output: 100))
    }
}

extension CoachBackend {
    static let test = CoachBackend(baseURL: URL(string: "https://worker.test/v1")!, token: "mc_test", viaWorker: true)
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
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, backend: .test),
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

    @Test func throttleFollowsTheConfiguredCooldownAndLimit() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let clock = Clock()
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, backend: .test,
                                                     cooldownSeconds: 30, maxCardsPerWindow: 1),
            llm: ScriptedCoachLLM(), elapsed: { clock.now }
        )
        coach.begin(recordingID: UUID())
        clock.now = 150
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 130, end: 150, text: "志明你覺得呢", arrivedAt: 150.5)))
        await waitUntil { coach.currentCard != nil }
        #expect(coach.currentCard?.candidate.version.policy == "trigger-r4;throttle-30-600-1-120")
        coach.dismissCurrentCard()

        // 40 s later clears the 30 s cooldown, but the limit of one per 10 minutes holds.
        clock.now = 190
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 170, end: 190, text: "要不要延期？", arrivedAt: 190.5)))
        await waitUntil { coach.ledgers.count == 2 && coach.ledgers[1].events.count == 2 }
        #expect(coach.ledgers[1].events.last?.kind == .suppressed(reason: "window_limit"))
        await coach.finish(at: 200)
    }

    @Test func discardingTheRecordingDeletesItsCoachRecord() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "我", budgetUSD: 10, backend: .test),
            llm: ScriptedCoachLLM(), elapsed: { 0 }
        )
        coach.begin(recordingID: UUID())
        await coach.finish(at: 1, discarding: true)
        #expect(try context.fetch(FetchDescriptor<CoachRecord>()).isEmpty)
    }

    @Test func discardingStopsPipelineImmediatelyWithoutNewRequestsOrLateWrites() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let llm = SlowJudgeCoachLLM()
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, backend: .test),
            llm: llm, elapsed: { 150 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 130, end: 150, text: "志明你覺得呢", arrivedAt: 150)))
        await waitUntil { llm.calls == ["judge"] }

        // Discard while judge is still in flight.
        await coach.finish(at: 155, discarding: true)
        // Now deliver the late judge response and let any stray tasks settle.
        llm.releaseJudge()
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        // No card LLM call was issued after discard, and no late write recreated or mutated records.
        #expect(llm.calls == ["judge"])
        #expect(coach.ledgers.isEmpty)
        #expect(try context.fetch(FetchDescriptor<CoachRecord>()).isEmpty)
    }

    @Test(arguments: [(402, MeetingCoachSession.StopReason.quota), (401, .unauthorized)])
    func workerRefusalStopsTheAIButKeepsTheSession(status: Int, reason: MeetingCoachSession.StopReason) async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "我", budgetUSD: 10, backend: .test),
            llm: RefusingCoachLLM(status: status), elapsed: { 200 }
        )
        nonisolated(unsafe) var stopped = false
        coach.onStopAI = { stopped = true }
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable }
        await coach.askForCard()
        #expect(coach.stopReason == reason)
        #expect(stopped)
        // The transcript received so far is still kept.
        await coach.finish(at: 210)
        #expect(try context.fetch(FetchDescriptor<CoachRecord>()).first?.segments.count == 1)
    }

    @Test func liveSpendIsAddedToWhatThePostMeetingRunAlreadyRecorded() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let clock = Clock()
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "我", budgetUSD: 10, backend: .test),
            llm: ScriptedCoachLLM(), elapsed: { clock.now }
        )
        coach.begin(recordingID: UUID())
        let record = try #require(try context.fetch(FetchDescriptor<CoachRecord>()).first)
        record.costUSD += 1   // e.g. the follow-up's transcription landed first
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable }
        await coach.askForCard()
        await coach.finish(at: 30)
        #expect(abs(record.costUSD - (1 + coach.cost.totalUSD)) < 1e-9)
    }

    @Test func workerBaseURLAndSummaryOutput() throws {
        #expect(CoachBackend.workerBaseURL("https://api.example.com/")?.absoluteString == "https://api.example.com/v1")
        #expect(CoachBackend.workerBaseURL(" https://api.example.com/v1 ")?.absoluteString == "https://api.example.com/v1")
        #expect(CoachBackend.workerBaseURL("http://api.example.com") == nil)
        #expect(CoachBackend.workerBaseURL("") == nil)
        let root: [String: Any] = ["output": [
            ["type": "reasoning", "summary": []],
            ["type": "message", "content": [["type": "output_text", "text": "## 共識\n"], ["type": "output_text", "text": "- 上線"]]]
        ]]
        #expect(CoachSummaryProvider.outputText(root) == "## 共識\n- 上線")
    }

    @Test func nameMatcherAcceptsHomophones() {
        let matches = ChineseText.nameMatcher(for: "志明")
        #expect(matches("致明你先講"))
        #expect(matches("那智明呢"))
        #expect(!matches("說明一下"))
        #expect(ChineseText.traditional("向量数据库在尖峰时间") == "向量數據庫在尖峰時間")
    }
}
