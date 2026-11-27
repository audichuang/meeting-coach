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

/// Simulates a judge request that hits a transient failure, sleeps in retry
/// backoff (like `LLMHTTP.sendValidated` on HTTP 429/5xx), and sends a retry
/// attempt unless its task is cancelled.
private final class RetryingJudgeCoachLLM: CoachLLM, @unchecked Sendable {
    private let lock = NSLock()
    private let refuseAskStatus: Int?
    private var recordedCalls: [String] = []
    private var backoffContinuation: CheckedContinuation<Void, Error>?
    private var enteredBackoff = false
    private var released = false

    init(refuseAskStatus: Int? = nil) {
        self.refuseAskStatus = refuseAskStatus
    }

    var calls: [String] { lock.withLock { recordedCalls } }
    var isInBackoff: Bool { lock.withLock { enteredBackoff } }

    func releaseBackoff() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            released = true
            let current = backoffContinuation
            backoffContinuation = nil
            return current
        }
        continuation?.resume()
    }

    func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult {
        let name = tools[0].name
        if name == "emit_suggestion", let status = refuseAskStatus {
            lock.withLock { recordedCalls.append(name) }
            throw AppError.apiError(statusCode: status, message: "refused")
        }
        guard name == "judge" else {
            lock.withLock { recordedCalls.append(name) }
            let args = #"{"short_text":"先對齊目標？","reason":"目標不同","evidence_start":0,"evidence_end":1,"category":"clarify"}"#
            return CoachCallResult(calls: [CoachToolCall(name: name, arguments: Data(args.utf8))],
                                   usage: CoachTokenUsage(input: 1_000, cached: 0, output: 100))
        }
        lock.withLock { recordedCalls.append("judge#1") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Action { case wait, resume, cancel }
                let action: Action = lock.withLock {
                    enteredBackoff = true
                    if Task.isCancelled { return .cancel }
                    if released { return .resume }
                    backoffContinuation = continuation
                    return .wait
                }
                switch action {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                let current = self.backoffContinuation
                self.backoffContinuation = nil
                return current
            }
            continuation?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
        lock.withLock { recordedCalls.append("judge#2") }
        let args = #"{"decision":"emit","reason":"分歧"}"#
        return CoachCallResult(calls: [CoachToolCall(name: name, arguments: Data(args.utf8))],
                               usage: CoachTokenUsage(input: 1_000, cached: 0, output: 100))
    }
}

/// Holds an ask (`emit_suggestion`) or wrap-up (`emit_wrapup`) call until
/// released (optionally cancelling on task cancellation to model retry backoff
/// in `LLMHTTP.sendValidated`, or returning a late response even if cancelled).
/// Judge calls return HTTP 402 so a test can trigger `stopAI(.quota)` while
/// ask or wrap-up is in flight.
private final class GatedActionCoachLLM: CoachLLM, @unchecked Sendable {
    private let lock = NSLock()
    private let targetTool: String
    private let cancelDuringWait: Bool
    private var recordedCalls: [String] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var waiting = false
    private var released = false

    init(targetTool: String, cancelDuringWait: Bool) {
        self.targetTool = targetTool
        self.cancelDuringWait = cancelDuringWait
    }

    var calls: [String] { lock.withLock { recordedCalls } }
    var isWaiting: Bool { lock.withLock { waiting } }

    func release() {
        let current = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            released = true
            let cont = continuation
            continuation = nil
            return cont
        }
        current?.resume()
    }

    func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult {
        let name = tools[0].name
        if name == "judge" {
            lock.withLock { recordedCalls.append("judge") }
            throw AppError.apiError(statusCode: 402, message: "quota")
        }
        guard name == targetTool else {
            lock.withLock { recordedCalls.append(name) }
            return CoachCallResult(calls: [], usage: CoachTokenUsage(input: 100, cached: 0, output: 10))
        }
        lock.withLock { recordedCalls.append("\(name)#1") }
        if cancelDuringWait {
            try await withTaskCancellationHandler {
                try await waitUntilReleased(checkTaskCancellation: true)
            } onCancel: {
                let current = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    let cont = self.continuation
                    self.continuation = nil
                    return cont
                }
                current?.resume(throwing: CancellationError())
            }
            try Task.checkCancellation()
            lock.withLock { recordedCalls.append("\(name)#2") }
        } else {
            try await waitUntilReleased(checkTaskCancellation: false)
        }
        let args: String = name == "emit_wrapup"
            ? #"{"common_goal":"g","disagreements":"d","open_questions":"o","next_steps":"n","spoken_text":"收尾"}"#
            : #"{"short_text":"先對齊目標？","reason":"目標不同","evidence_start":0,"evidence_end":1,"category":"clarify"}"#
        return CoachCallResult(
            calls: [CoachToolCall(name: name, arguments: Data(args.utf8))],
            usage: CoachTokenUsage(input: 1_000, cached: 0, output: 100)
        )
    }

    private func waitUntilReleased(checkTaskCancellation: Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            enum Action { case wait, resume, cancel }
            let action: Action = lock.withLock {
                waiting = true
                if checkTaskCancellation && Task.isCancelled { return .cancel }
                if released { return .resume }
                continuation = cont
                return .wait
            }
            switch action {
            case .wait: break
            case .resume: cont.resume()
            case .cancel: cont.resume(throwing: CancellationError())
            }
        }
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

    @Test func cancellingWithQueuedTriggerCancelsEarlierJudgeInBackoff() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let llm = RetryingJudgeCoachLLM()
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, backend: .test),
            llm: llm, elapsed: { 150 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 130, end: 150, text: "志明你覺得呢", arrivedAt: 150)))
        await waitUntil { llm.isInBackoff }

        // A second trigger arrives while the first judge call is blocked in retry backoff.
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 150, end: 170, text: "要不要延期？", arrivedAt: 170)))
        await waitUntil { coach.segments.count == 2 }
        await Task.yield()

        coach.cancel()
        llm.releaseBackoff()
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        // Neither the first judge retry nor the queued second trigger may send another request.
        #expect(llm.calls == ["judge#1"])
    }

    @Test func stopAIWithQueuedTriggerCancelsEarlierJudgeInBackoff() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let llm = RetryingJudgeCoachLLM(refuseAskStatus: 402)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, backend: .test),
            llm: llm, elapsed: { 150 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 130, end: 150, text: "志明你覺得呢", arrivedAt: 150)))
        await waitUntil { llm.isInBackoff }

        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 150, end: 170, text: "要不要延期？", arrivedAt: 170)))
        await waitUntil { coach.segments.count == 2 }
        await Task.yield()

        await coach.askForCard()
        #expect(coach.stopReason == .quota)

        llm.releaseBackoff()
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(llm.calls == ["judge#1", "emit_suggestion"])
        await coach.finish(at: 180)
    }

    @Test func stopAICancelsInFlightAskRetryWithoutSendingAnotherAttempt() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let llm = GatedActionCoachLLM(targetTool: "emit_suggestion", cancelDuringWait: true)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, backend: .test),
            llm: llm, elapsed: { 150 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable }

        let ask = Task { await coach.askForCard() }
        await waitUntil { llm.isWaiting }

        // A triggered judge hits HTTP 402 -> stopAI(.quota) while ask is in retry backoff.
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 130, end: 150, text: "志明你覺得呢", arrivedAt: 150)))
        await waitUntil { coach.stopReason == .quota }

        llm.release()
        await ask.value

        let record = try #require(try context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(!llm.calls.contains("emit_suggestion#2"))
        #expect(coach.ledgers.isEmpty)
        #expect(coach.currentCard == nil)
        #expect(coach.cost.totalUSD == 0)
        #expect(record.ledgers.isEmpty)
        #expect(record.costUSD == 0)
        #expect(!coach.isAsking)
        await coach.finish(at: 180)
    }

    @Test func stopAIBlocksLateAskResponseFromMutatingStateOrSaving() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let llm = GatedActionCoachLLM(targetTool: "emit_suggestion", cancelDuringWait: false)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, backend: .test),
            llm: llm, elapsed: { 150 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable }

        let ask = Task { await coach.askForCard() }
        await waitUntil { llm.isWaiting }

        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 130, end: 150, text: "志明你覺得呢", arrivedAt: 150)))
        await waitUntil { coach.stopReason == .quota }

        // Late HTTP response arrives after stopAI.
        llm.release()
        await ask.value

        let record = try #require(try context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(coach.ledgers.isEmpty)
        #expect(coach.currentCard == nil)
        #expect(coach.cost.totalUSD == 0)
        #expect(record.ledgers.isEmpty)
        #expect(record.costUSD == 0)
        #expect(!coach.isAsking)
        await coach.finish(at: 180)
    }

    @Test func stopAICancelsInFlightWrapUpRetryWithoutSendingAnotherAttempt() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let llm = GatedActionCoachLLM(targetTool: "emit_wrapup", cancelDuringWait: true)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, backend: .test),
            llm: llm, elapsed: { 150 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable }

        let wrapUp = Task { await coach.requestWrapUp() }
        await waitUntil { llm.isWaiting }

        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 130, end: 150, text: "志明你覺得呢", arrivedAt: 150)))
        await waitUntil { coach.stopReason == .quota }

        llm.release()
        await wrapUp.value

        let record = try #require(try context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(!llm.calls.contains("emit_wrapup#2"))
        #expect(coach.wrapUp == nil)
        #expect(record.wrapUp == nil)
        #expect(coach.cost.totalUSD == 0)
        #expect(record.costUSD == 0)
        #expect(!coach.isWrappingUp)
        await coach.finish(at: 180)
    }

    @Test func stopAIBlocksLateWrapUpResponseFromMutatingStateOrSaving() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let llm = GatedActionCoachLLM(targetTool: "emit_wrapup", cancelDuringWait: false)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "志明", budgetUSD: 10, backend: .test),
            llm: llm, elapsed: { 150 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable }

        let wrapUp = Task { await coach.requestWrapUp() }
        await waitUntil { llm.isWaiting }

        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 130, end: 150, text: "志明你覺得呢", arrivedAt: 150)))
        await waitUntil { coach.stopReason == .quota }

        llm.release()
        await wrapUp.value

        let record = try #require(try context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(coach.wrapUp == nil)
        #expect(record.wrapUp == nil)
        #expect(coach.cost.totalUSD == 0)
        #expect(record.costUSD == 0)
        #expect(!coach.isWrappingUp)
        await coach.finish(at: 180)
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

    @Test func missingBuildConfigurationStopsTheAIWithItsOwnReason() async throws {
        struct NotConfiguredLLM: CoachLLM {
            func call(model: String, instructions: String, input: String, tools: [CoachTool], force: String?) async throws -> CoachCallResult {
                throw CoachBackend.NotConfigured()
            }
        }
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "我", budgetUSD: 10, backend: .test),
            llm: NotConfiguredLLM(), elapsed: { 200 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable }
        await coach.askForCard()
        #expect(coach.stopReason == .accessMissing)
        await coach.finish(at: 210)
    }

    @Test func stopAIIgnoresLateTranscriptAndBillingEvents() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "我", budgetUSD: 10, backend: .test),
            llm: RefusingCoachLLM(status: 402), elapsed: { 200 }
        )
        coach.begin(recordingID: UUID())
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable }
        await coach.askForCard()
        #expect(coach.stopReason == .quota)

        // Late live-transcription events arriving after stopAI must not mutate state or spend.
        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 20, end: 40, text: "晚到的逐字", arrivedAt: 40)))
        coach.eventSink.yield(.billedSeconds(20))
        await coach.finish(at: 210)

        let record = try #require(try context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(coach.segments.count == 1)
        #expect(record.segments.count == 1)
        #expect(coach.cost.transcribedSeconds == 0)
        #expect(coach.cost.totalUSD == 0)
        #expect(record.costUSD == 0)
    }

    @Test func cancelInvokesOnStopAI() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "我", budgetUSD: 10, backend: .test),
            llm: ScriptedCoachLLM(), elapsed: { 10 }
        )
        nonisolated(unsafe) var stopped = false
        coach.onStopAI = { stopped = true }
        coach.begin(recordingID: UUID())

        coach.cancel()

        #expect(stopped)
    }

    private final class StubRealtimeSocket: RealtimeSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var sentMessages: [String] = []
        private var isClosed = false
        private let incoming: AsyncThrowingStream<String, Error>
        private let feed: AsyncThrowingStream<String, Error>.Continuation
        private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator?

        init() {
            (incoming, feed) = AsyncThrowingStream.makeStream(of: String.self)
            iterator = incoming.makeAsyncIterator()
        }

        var sent: [String] { lock.withLock { sentMessages } }
        var closed: Bool { lock.withLock { isClosed } }
        func serverSends(_ json: String) { feed.yield(json) }

        func send(_ text: String) async throws { lock.withLock { sentMessages.append(text) } }
        func receive() async throws -> String {
            var it = lock.withLock { iterator! }
            let next = try await it.next()
            lock.withLock { iterator = it }
            guard let next else { throw URLError(.networkConnectionLost) }
            return next
        }
        func close() {
            lock.withLock { isClosed = true }
            feed.finish(throwing: CancellationError())
        }
    }

    @Test func stopAIStopsLiveSocketWithoutCommittingAudio() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coach")
        context.insert(meeting)
        let socket = StubRealtimeSocket()
        let opens = NSLock()
        nonisolated(unsafe) var openCount = 0
        let coach = MeetingCoachSession(
            meeting: meeting, modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "我", budgetUSD: 10, backend: .test),
            llm: RefusingCoachLLM(status: 402), elapsed: { 200 }
        )
        let live = coach.makeLiveTranscription(socketFactory: {
            opens.withLock { openCount += 1 }
            return socket
        })
        coach.begin(recordingID: UUID())
        await live.start(language: .chinese, modelsConsented: true)
        socket.serverSends(#"{"type":"session.created","session":{"expires_at":1}}"#)
        await waitUntil { coach.connection == .live }

        coach.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "大家好", arrivedAt: 20)))
        await waitUntil { coach.transcriptAvailable }
        await coach.askForCard()
        #expect(coach.stopReason == .quota)

        await waitUntil { socket.closed && !live.isActive }
        #expect(socket.closed)
        #expect(!socket.sent.contains(#"{"type":"input_audio_buffer.commit"}"#))
        #expect(opens.withLock { openCount } == 1)
        await coach.finish(at: 210)
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
