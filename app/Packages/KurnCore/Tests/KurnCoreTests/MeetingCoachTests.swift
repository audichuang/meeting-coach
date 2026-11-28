import Foundation
import Testing
@testable import KurnCore

struct MeetingCoachTests {
    // MARK: Realtime events and commit windows

    @Test func parsesRealtimeEventsFromTheSpikeLog() {
        let completed = #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","content_index":0,"transcript":"好，那我们开始","usage":{"type":"duration","seconds":10}}"#
        #expect(RealtimeServerEvent.parse(Data(completed.utf8)) == .completed(itemID: "item_1", transcript: "好，那我们开始", billedSeconds: 10))
        let created = #"{"type":"session.created","session":{"expires_at":1795737938}}"#
        #expect(RealtimeServerEvent.parse(Data(created.utf8)) == .sessionCreated(expiresAt: 1_795_737_938))
        let error = #"{"type":"error","error":{"code":"input_audio_buffer_commit_empty","message":"buffer too small"}}"#
        #expect(RealtimeServerEvent.parse(Data(error.utf8)) == .error(code: "input_audio_buffer_commit_empty", message: "buffer too small"))
        #expect(RealtimeServerEvent.parse(Data("not json".utf8)) == nil)
    }

    @Test func commitWindowsMapToRecordingTime() throws {
        var tracker = RealtimeCommitTracker(sampleRate: 100, window: 20)
        do { let r = tracker.sent(1_000); #expect(!r) }
        do { let r = tracker.sent(1_000); #expect(r) }           // 20 s reached
        do { let r = tracker.commit(); #expect(r) }
        tracker.acknowledge(itemID: "a")
        _ = tracker.sent(500)
        let maybeFirst = tracker.complete(itemID: "a", text: "x")
        let first = try #require(maybeFirst)
        #expect(first.start == 0 && first.end == 20 && first.arrivedAt == 25)
        do { let r = tracker.complete(itemID: "a", text: "x"); #expect(r == nil) }
    }

    @Test func disconnectTurnsUnfinishedAudioIntoGaps() {
        var tracker = RealtimeCommitTracker(sampleRate: 100, window: 20)
        _ = tracker.sent(2_000)
        do { let r = tracker.commit(); #expect(r) }                // [0, 20] committed, never acknowledged
        _ = tracker.sent(300)                    // [20, 23] appended, never committed
        do { let r = tracker.abandonWindow(); #expect(r == LiveTranscriptGap(start: 20, end: 23)) }
        do { let r = tracker.abandonPending(); #expect(r == [LiveTranscriptGap(start: 0, end: 20)]) }
        tracker.dropped(700)                     // offline 23–30 s
        _ = tracker.sent(500)
        do { let r = tracker.commit(); #expect(r) }
        tracker.acknowledge(itemID: "b")
        do { let r = tracker.complete(itemID: "b", text: "y"); #expect(r?.start == 30) }
    }

    @Test func tooShortCommitIsSkipped() {
        var tracker = RealtimeCommitTracker(sampleRate: 100, window: 20)
        _ = tracker.sent(5)
        do { let r = tracker.commit(); #expect(!r) }
    }

    // MARK: Cost and budget

    @Test func costMeterUsesPublishedRates() {
        var meter = CoachCostMeter()
        meter.addTranscription(seconds: 600)                 // 10 min * 0.017
        meter.addTokens(model: "gpt-6.1-terra", usage: .init(input: 3_000, cached: 1_000, output: 200), step: .cards)
        meter.addTokens(model: "unknown", usage: .init(input: 1_000_000, cached: 0, output: 0), step: .cards)
        let tokens: Double = 2_000 * 1 + 1_000 * 0.05 + 200 * 5
        let expected: Double = 0.17 + tokens / 1_000_000
        #expect(abs(meter.totalUSD - expected) < 1e-9)
    }

    @Test func costMeterAccumulatesEachStepSeparately() {
        var meter = CoachCostMeter()
        meter.addTranscription(seconds: 60)
        meter.addTokens(model: CoachPricing.judgeModel, usage: .init(input: 1_000_000, cached: 0, output: 0), step: .cards)
        meter.addTokens(model: CoachPricing.cardModel, usage: .init(input: 1_000_000, cached: 0, output: 0), step: .cards)
        meter.addTokens(model: CoachPricing.cardModel, usage: .init(input: 0, cached: 0, output: 1_000_000), step: .wrapUp)
        #expect(abs(meter.breakdown[.liveTranscript] - 0.017) < 1e-9)
        #expect(abs(meter.breakdown[.cards] - 1.10) < 1e-9)
        #expect(abs(meter.breakdown[.wrapUp] - 5) < 1e-9)
        #expect(meter.breakdown[.formalTranscript] == 0 && meter.breakdown[.summary] == 0)
        #expect(abs(meter.totalUSD - meter.breakdown.totalUSD) < 1e-12)
        #expect(abs(meter.totalUSD - 6.117) < 1e-9)
    }

    @Test func breakdownDifferenceIsWhatWasAddedSince() {
        var before = CoachCostBreakdown()
        before[.cards] = 0.5
        var after = before
        after[.cards] += 0.25
        after[.liveTranscript] = 1
        let delta = after - before
        #expect(abs(delta[.cards] - 0.25) < 1e-12)
        #expect(delta[.liveTranscript] == 1)
        #expect(abs((before + delta).totalUSD - after.totalUSD) < 1e-12)
    }

    @Test func meetingBreakdownSumsRecordingsAndIsUnknownIfAnyIsUnknown() {
        var first = CoachCostBreakdown()
        first[.liveTranscript] = 1
        first[.summary] = 0.02
        var second = CoachCostBreakdown()
        second[.liveTranscript] = 0.5
        second[.formalTranscript] = 0.1
        let sum = CoachCostBreakdown.sum([first, second])
        #expect(sum?[.liveTranscript] == 1.5)
        #expect(sum?[.formalTranscript] == 0.1)
        #expect(sum?[.summary] == 0.02)
        #expect(sum?[.cards] == 0)
        #expect(CoachCostBreakdown.sum([first, nil]) == nil)
        #expect(CoachCostBreakdown.sum([]) == CoachCostBreakdown())
    }

    @Test func breakdownRoundTripsThroughJSON() throws {
        var value = CoachCostBreakdown()
        value[.wrapUp] = 0.03
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(CoachCostBreakdown.self, from: data) == value)
    }

    @Test func budgetWarnsThenStopsAfterGrace() {
        let t0 = Date(timeIntervalSince1970: 0)
        var guardrail = CoachBudgetGuard(threshold: 10, grace: 300)
        do { let r = guardrail.update(cost: 9.99, now: t0); #expect(r == .normal) }
        do { let r = guardrail.update(cost: 10, now: t0); #expect(r == .warning(since: t0)) }
        do { let r = guardrail.update(cost: 10.5, now: t0.addingTimeInterval(299)); #expect(r == .warning(since: t0)) }
        do { let r = guardrail.update(cost: 10.5, now: t0.addingTimeInterval(300)); #expect(r == .stopped) }
    }

    @Test func continuingRearmsOneThresholdHigher() {
        let t0 = Date(timeIntervalSince1970: 0)
        var guardrail = CoachBudgetGuard(threshold: 10)
        guardrail.update(cost: 10.2, now: t0)
        guardrail.continueSpending(cost: 10.2)
        do { let r = guardrail.update(cost: 19.9, now: t0); #expect(r == .normal) }
        do { let r = guardrail.update(cost: 20, now: t0); #expect(r == .warning(since: t0)) }
    }

    // MARK: Trigger and throttle

    private func seg(_ text: String, at: TimeInterval) -> LiveTranscriptSegment {
        LiveTranscriptSegment(start: at - 20, end: at, text: text, arrivedAt: at + 0.5)
    }

    @Test func triggerFiresOnQuestionsNamesAndFallback() {
        var trigger = EventSuggestionTrigger { $0.contains("志明") }
        do { let r = trigger.events(for: seg("目前 QA 跑了三週。", at: 40)); #expect(r.isEmpty) }
        do { let r = trigger.events(for: seg("那要不要延到一月？", at: 60)); #expect(r == ["問句"]) }
        do { let r = trigger.events(for: seg("志明你先講工程", at: 80)); #expect(r == ["點名使用者"]) }
        do { let r = trigger.events(for: seg("We should check what latency is", at: 100)); #expect(r == ["問句"]) }
        do { let r = trigger.events(for: seg("好。", at: 200)); #expect(r.isEmpty) }
        do { let r = trigger.events(for: seg("好。", at: 300)); #expect(r == ["3 分鐘保底"]) }
    }

    @Test func throttleKeepsOpeningQuietGapAndWindow() throws {
        let throttle = SuggestionThrottle(minimumGap: 90, window: 600, maximumInWindow: 3, openingQuiet: 120)
        #expect(try throttle.decide(at: 100, shownOffsets: []) == .suppress(reason: "opening"))
        #expect(try throttle.decide(at: 147, shownOffsets: []) == .show)
        #expect(try throttle.decide(at: 207, shownOffsets: [147]) == .suppress(reason: "minimum_gap"))
        #expect(try throttle.decide(at: 500, shownOffsets: [147, 287, 447]) == .suppress(reason: "minimum_gap"))
        #expect(try throttle.decide(at: 600, shownOffsets: [147, 287, 447]) == .suppress(reason: "window_limit"))
    }

    @Test func messagesMatchTheSpikeShape() {
        let segments = [seg("第一段", at: 20), seg("第二段？", at: 240)]
        let msg = CoachMessages.trigger(segments: segments, now: 240.5, events: ["問句"], cards: [])
        #expect(msg == "## 最近 3 分鐘逐字稿（到第 240 秒）\n[220–240] 第二段？\n\n## 偵測到的事件\n問句\n\n## 已出過的卡\n（尚無）")
        #expect(CoachMessages.instructions(CoachPrompts.card, user: "志明").contains("你的使用者是「志明」"))
        #expect(CoachMessages.wrapUp(segments: segments).hasPrefix("## 會議逐字稿（完整）\n[0–20] 第一段\n[220–240] 第二段？\n\n會議結束了"))
    }

    @Test func promptRenderingMarksSelfSpeakerAsUserAcrossGateCardAskAndWrapUp() {
        let segments = [
            LiveTranscriptSegment(start: 0, end: 20, text: "我們先確認範圍。", arrivedAt: 20.5, speakerLabel: "A"),
            LiveTranscriptSegment(start: 20, end: 40, text: "下週可以上線嗎？", arrivedAt: 40.5, speakerLabel: "B"),
            LiveTranscriptSegment(start: 40, end: 60, text: "無標籤補充。", arrivedAt: 60.5, speakerLabel: nil)
        ]

        let unmarkedTrigger = CoachMessages.trigger(segments: segments, now: 61, events: ["問句"], cards: [], selfSpeakerLabel: nil)
        #expect(unmarkedTrigger.contains("[0–20] A: 我們先確認範圍。"))
        #expect(unmarkedTrigger.contains("[20–40] B: 下週可以上線嗎？"))
        #expect(unmarkedTrigger.contains("[40–60] 無標籤補充。"))
        #expect(!unmarkedTrigger.contains("使用者:"))

        let markedTrigger = CoachMessages.trigger(segments: segments, now: 61, events: ["問句"], cards: [], selfSpeakerLabel: "A")
        #expect(markedTrigger.contains("[0–20] 使用者: 我們先確認範圍。"))
        #expect(markedTrigger.contains("[20–40] B: 下週可以上線嗎？"))
        #expect(markedTrigger.contains("[40–60] 無標籤補充。"))

        let markedAsk = CoachMessages.ask(segments: segments, now: 61, cards: [], selfSpeakerLabel: "B")
        #expect(markedAsk.contains("[0–20] A: 我們先確認範圍。"))
        #expect(markedAsk.contains("[20–40] 使用者: 下週可以上線嗎？"))

        let markedWrapUp = CoachMessages.wrapUp(segments: segments, selfSpeakerLabel: "A")
        #expect(markedWrapUp.contains("[0–20] 使用者: 我們先確認範圍。"))
        #expect(markedWrapUp.contains("[20–40] B: 下週可以上線嗎？"))

        #expect(CoachPrompts.card.contains("使用者"))
        #expect(CoachPrompts.card.contains("不要重述使用者"))
        #expect(CoachPrompts.judge.contains("使用者"))
    }

    @Test func toolSchemasAreValidJSON() throws {
        for schema in [CoachPrompts.emitSuggestionSchema, CoachPrompts.emitWrapupSchema, CoachPrompts.judgeSchema] {
            #expect(try JSONSerialization.jsonObject(with: Data(schema.utf8)) is [String: Any])
        }
    }
}
