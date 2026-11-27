//
//  MeetingCoachSession.swift
//  Kurn
//
//  One recording's meeting coach: consumes the cloud live transcript
//  (`LiveTranscriptEvent`), keeps it in Traditional Chinese, meters spend,
//  runs the suggestion pipeline (trigger -> judge -> card -> throttle) and
//  persists everything to a `CoachRecord` as it happens.
//
//  It deliberately outlives `RecorderViewModel`: the recorder stops the live
//  transcriber fire-and-forget, and the last window's final arrives after the
//  view model is gone, so the event-stream task keeps this object alive until
//  `finish(at:)` runs.
//

import Foundation
import KurnCore
import Observation
import SwiftData

struct MeetingCoachConfiguration: Sendable {
    var userName: String
    var budgetUSD: Double
    var backend: CoachBackend
    /// Automatic-card throttle (decisions: 90 s gap, at most 3 per 10 minutes, adjustable).
    var cooldownSeconds: Double = 90
    var maxCardsPerWindow = 3

    /// `nil` when the coach is off or has no backend configured (nothing is sent).
    @MainActor
    static func resolve(settings: AppSettings) -> MeetingCoachConfiguration? {
        guard settings.meetingCoachEnabled, let backend = CoachBackend.current() else { return nil }
        let name = settings.coachUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingCoachConfiguration(userName: name, budgetUSD: settings.coachBudgetUSD, backend: backend,
                                         cooldownSeconds: settings.coachCooldownSeconds,
                                         maxCardsPerWindow: settings.coachMaxCardsPerWindow)
    }
}

@MainActor
@Observable
final class MeetingCoachSession {
    /// Why AI processing stopped while the recording goes on.
    enum StopReason: Equatable {
        /// The per-meeting spend warning went unanswered.
        case budget
        /// The Worker's monthly cap is spent (HTTP 402).
        case quota
        /// The Worker rejected the invite code (HTTP 401).
        case unauthorized
    }

    static let promptVersion = "spike-r4"

    private(set) var segments: [LiveTranscriptSegment] = []
    private(set) var gaps: [LiveTranscriptGap] = []
    private(set) var connection: LiveConnectionState = .connecting
    private(set) var cost = CoachCostMeter()
    private(set) var budget: CoachBudgetGuard
    private(set) var stopReason: StopReason?
    var isAIStopped: Bool { stopReason != nil }
    private(set) var ledgers: [CoachLedgerRecord] = []
    /// The one card currently on screen.
    private(set) var currentCardID: UUID?
    private(set) var isAsking = false
    private(set) var isWrappingUp = false
    private(set) var wrapUp: CoachWrapUpArguments?
    private(set) var lastError: String?

    let userName: String
    @ObservationIgnored let events: AsyncStream<LiveTranscriptEvent>
    @ObservationIgnored let eventSink: AsyncStream<LiveTranscriptEvent>.Continuation
    @ObservationIgnored private let llm: any CoachLLM
    @ObservationIgnored private let backend: CoachBackend
    /// The live meter's total as last written, so `save()` adds only new live
    /// spend to `CoachRecord.costUSD`, which the post-meeting run also adds to.
    @ObservationIgnored private var savedLiveCost = 0.0
    @ObservationIgnored private var trigger: any SuggestionTriggerStrategy
    @ObservationIgnored private let throttle: SuggestionThrottle
    /// Stamped on every automatic card, so the ledger records the throttle it ran under.
    var policyVersion: String {
        "trigger-r4;throttle-\(Int(throttle.minimumGap))-\(Int(throttle.window))-\(throttle.maximumInWindow)-\(Int(throttle.openingQuiet))"
    }
    @ObservationIgnored private let meeting: Meeting
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let elapsed: @MainActor () -> TimeInterval
    @ObservationIgnored private var record: CoachRecord?
    @ObservationIgnored private(set) var recordingID: UUID?
    @ObservationIgnored private var triggerLog: [CoachTriggerRecord] = []
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var budgetTimer: Task<Void, Never>?
    @ObservationIgnored private var aiStoppedAt: TimeInterval?
    /// Stops cloud transcription when the budget guard fires; recording continues.
    @ObservationIgnored var onStopAI: (@MainActor () -> Void)?

    init(
        meeting: Meeting,
        modelContext: ModelContext,
        configuration: MeetingCoachConfiguration,
        llm: (any CoachLLM)? = nil,
        trigger: (any SuggestionTriggerStrategy)? = nil,
        elapsed: @escaping @MainActor () -> TimeInterval
    ) {
        self.meeting = meeting
        self.modelContext = modelContext
        // No name configured: prompts say "使用者" and the named-user event is off.
        self.userName = configuration.userName.isEmpty ? "使用者" : configuration.userName
        self.backend = configuration.backend
        self.budget = CoachBudgetGuard(threshold: configuration.budgetUSD)
        self.throttle = SuggestionThrottle(minimumGap: max(0, configuration.cooldownSeconds), window: 600,
                                           maximumInWindow: max(1, configuration.maxCardsPerWindow), openingQuiet: 120)
        self.llm = llm ?? CoachResponsesClient(backend: configuration.backend)
        self.trigger = trigger ?? EventSuggestionTrigger(mentionsUser: ChineseText.nameMatcher(for: configuration.userName))
        self.elapsed = elapsed
        (events, eventSink) = AsyncStream.makeStream(of: LiveTranscriptEvent.self)
    }

    /// The live-transcription service the recorder feeds, backed by the cloud
    /// transcriber instead of an on-device model. Stopping it is how the budget
    /// guard halts AI processing without touching the recording.
    func makeLiveTranscription() -> LiveTranscriptionService {
        let sink = eventSink
        let open = OpenAILiveTranscriber.socketFactory(backend: backend)
        let socket: OpenAILiveTranscriber.SocketFactory = { [weak self] in
            do {
                return try await open()
            } catch {
                await self?.handleServiceError(error)
                throw error
            }
        }
        let live = LiveTranscriptionService(engineFactory: { _, _ in
            let engine = OpenAILiveTranscriber(makeSocket: socket) { sink.yield($0) }
            try await engine.loadModels()
            return engine
        })
        onStopAI = { [weak live] in
            guard let live else { return }
            Task { await live.stop() }
        }
        return live
    }

    var currentCard: CoachLedgerRecord? { ledgers.first { $0.candidate.id == currentCardID } }
    var transcriptAvailable: Bool { !segments.isEmpty }
    var isBudgetWarning: Bool { if case .warning = budget.state { return true }; return false }

    // MARK: Lifecycle

    /// Called once capture owns a recording; starts consuming transcript events.
    func begin(recordingID: UUID) {
        self.recordingID = recordingID
        let record = CoachRecord(meeting: meeting, recordingID: recordingID, userName: userName)
        modelContext.insert(record)
        self.record = record
        save()
        Task { [self] in
            for await event in events { handle(event) }
        }
    }

    /// The transcriber has stopped; close open gaps and persist the final state.
    /// A discarded recording takes its coach record with it.
    func finish(at end: TimeInterval, discarding: Bool = false) async {
        eventSink.finish()
        await pipeline?.value
        budgetTimer?.cancel()
        if discarding, let record {
            modelContext.delete(record)
            self.record = nil
            if let failure = modelContext.saveOrError() {
                AppLog.persistence.atError.error("MeetingCoachSession: discard failed code=\(failure.logCode, privacy: .public)")
            }
            return
        }
        if let start = aiStoppedAt { addGap(LiveTranscriptGap(start: start, end: max(start, end))) }
        save()
    }

    private func handle(_ event: LiveTranscriptEvent) {
        switch event {
        case .partial:
            break
        case .final(var segment):
            #if DEBUG
            Self.debugAppendRawFinal(segment)
            #endif
            segment.text = ChineseText.traditional(segment.text)
            segments.append(segment)
            save()
            evaluateTrigger(for: segment)
        case .connection(let state):
            connection = state
        case .gap(let gap):
            addGap(gap)
            save()
        case .billedSeconds(let seconds):
            cost.addTranscription(seconds: seconds)
            updateBudget()
        }
    }

    #if DEBUG
    /// Development only: the model's untouched text, for measuring CER before conversion.
    private static func debugAppendRawFinal(_ segment: LiveTranscriptSegment) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coach-raw-finals.jsonl")
        guard var line = try? JSONEncoder().encode(segment) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
    #endif

    private func addGap(_ gap: LiveTranscriptGap) {
        guard gap.end > gap.start else { return }
        if let last = gaps.last, gap.start <= last.end + 0.5 {
            gaps[gaps.count - 1].end = max(last.end, gap.end)
        } else {
            gaps.append(gap)
        }
    }

    // MARK: Budget

    private func updateBudget() {
        let state = budget.update(cost: cost.totalUSD, now: Date())
        if case .warning = state, budgetTimer == nil {
            budgetTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self else { return }
                    if self.budget.update(cost: self.cost.totalUSD, now: Date()) == .stopped {
                        self.stopAI(.budget)
                        return
                    }
                    if case .normal = self.budget.state { self.budgetTimer = nil; return }
                }
            }
        }
        if state == .stopped { stopAI(.budget) }
    }

    func continueAfterBudgetWarning() {
        budget.continueSpending(cost: cost.totalUSD)
        budgetTimer?.cancel()
        budgetTimer = nil
    }

    private func stopAI(_ reason: StopReason) {
        guard !isAIStopped else { return }
        stopReason = reason
        aiStoppedAt = elapsed()
        pipeline?.cancel()
        onStopAI?()
        AppLog.generation.atNotice.notice("MeetingCoachSession: AI processing stopped reason=\(String(describing: reason), privacy: .public)")
    }

    /// A Worker refusal no retry can fix stops the AI (recording continues); anything else is left to the caller.
    private func handleServiceError(_ error: Error) {
        if error.isCoachQuotaExhausted {
            stopAI(.quota)
        } else if error.isCoachUnauthorized {
            stopAI(.unauthorized)
        }
    }

    // MARK: Suggestions

    private var cardTool: CoachTool {
        // The spike's schema description still names the round-1 persona; substitute the user.
        CoachTool(name: "emit_suggestion", description: "顯示一張靜默建議卡給使用者",
                  parameters: CoachPrompts.emitSuggestionSchema.replacingOccurrences(of: "雅婷", with: userName))
    }

    private var cardInstructions: String { CoachMessages.instructions(CoachPrompts.card, user: userName) }

    private var previousCardTexts: [String] { ledgers.map(\.candidate.shortText) }

    private func evaluateTrigger(for segment: LiveTranscriptSegment) {
        guard !isAIStopped else { return }
        let labels = trigger.events(for: segment)
        guard !labels.isEmpty else { return }
        let previous = pipeline
        pipeline = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, !self.isAIStopped else { return }
            await self.runPipeline(segment: segment, labels: labels)
        }
    }

    private func runPipeline(segment: LiveTranscriptSegment, labels: [String]) async {
        let input = CoachMessages.trigger(segments: segments, now: segment.arrivedAt, events: labels, cards: previousCardTexts)
        do {
            let judgeTool = CoachTool(name: "judge", description: "回答要不要出卡", parameters: CoachPrompts.judgeSchema)
            let judged = try await llm.call(model: CoachPricing.judgeModel,
                                            instructions: CoachMessages.instructions(CoachPrompts.judge, user: userName),
                                            input: input, tools: [judgeTool], force: "judge")
            account(model: CoachPricing.judgeModel, judged.usage)
            let verdict = judged.calls.first.flatMap { try? JSONDecoder().decode(CoachJudgeArguments.self, from: $0.arguments) }
            logTrigger(offset: segment.arrivedAt, labels: labels, decision: verdict?.decision ?? "error", reason: verdict?.reason ?? "")
            guard verdict?.decision == "emit", !isAIStopped else { return }
            let carded = try await llm.call(model: CoachPricing.cardModel, instructions: cardInstructions,
                                            input: input, tools: [cardTool], force: nil)
            account(model: CoachPricing.cardModel, carded.usage)
            guard let args = Self.card(from: carded) else {
                logTrigger(offset: segment.arrivedAt, labels: labels, decision: "card_declined", reason: "")
                return
            }
            try addCandidate(args, evidence: segment, policy: policyVersion, gated: true)
        } catch {
            lastError = error.localizedDescription
            handleServiceError(error)
            logTrigger(offset: segment.arrivedAt, labels: labels, decision: "error", reason: error.publicLogCode)
            AppLog.generation.atError.error("MeetingCoachSession: pipeline failed code=\(error.publicLogCode, privacy: .public)")
        }
    }

    /// 「我該說什麼」: bypasses the judge and the throttle.
    func askForCard() async {
        guard !isAsking, !isAIStopped, let last = segments.last else { return }
        isAsking = true
        defer { isAsking = false }
        let input = CoachMessages.ask(segments: segments, now: elapsed(), cards: previousCardTexts)
        do {
            let result = try await llm.call(model: CoachPricing.cardModel, instructions: cardInstructions,
                                            input: input, tools: [cardTool], force: "emit_suggestion")
            account(model: CoachPricing.cardModel, result.usage)
            guard let args = Self.card(from: result) else { return }
            try addCandidate(args, evidence: last, policy: "ask", gated: false)
        } catch {
            lastError = error.localizedDescription
            handleServiceError(error)
            AppLog.generation.atError.error("MeetingCoachSession: ask failed code=\(error.publicLogCode, privacy: .public)")
        }
    }

    func requestWrapUp() async {
        guard !isWrappingUp, !isAIStopped, !segments.isEmpty else { return }
        isWrappingUp = true
        defer { isWrappingUp = false }
        let tool = CoachTool(name: "emit_wrapup", description: "顯示收尾整理", parameters: CoachPrompts.emitWrapupSchema)
        do {
            let result = try await llm.call(model: CoachPricing.cardModel, instructions: cardInstructions,
                                            input: CoachMessages.wrapUp(segments: segments), tools: [tool], force: "emit_wrapup")
            account(model: CoachPricing.cardModel, result.usage)
            wrapUp = result.calls.first.flatMap { try? JSONDecoder().decode(CoachWrapUpArguments.self, from: $0.arguments) }
            record?.wrapUp = wrapUp
            save()
        } catch {
            lastError = error.localizedDescription
            handleServiceError(error)
            AppLog.generation.atError.error("MeetingCoachSession: wrap-up failed code=\(error.publicLogCode, privacy: .public)")
        }
    }

    func dismissWrapUp() { wrapUp = nil }

    private static func card(from result: CoachCallResult) -> CoachCardArguments? {
        result.calls.first { $0.name == "emit_suggestion" }
            .flatMap { try? JSONDecoder().decode(CoachCardArguments.self, from: $0.arguments) }
    }

    private func addCandidate(_ args: CoachCardArguments, evidence segment: LiveTranscriptSegment, policy: String, gated: Bool) throws {
        let evidence = try SuggestionEvidence(recordingID: recordingID ?? UUID(), start: segment.start, end: segment.end, context: segment.text)
        let candidate = SuggestionCandidate(meetingID: meeting.id, shortText: args.shortText, fullText: args.shortText,
                                            reason: args.reason, evidence: [evidence],
                                            version: SuggestionVersion(model: CoachPricing.cardModel, prompt: Self.promptVersion, policy: policy))
        let now = elapsed()
        var ledger = try SuggestionLedger(candidate: candidate, createdAt: Date(), meetingOffset: now)
        // Candidate and its `created` event are durable before the gate runs.
        ledgers.append(CoachLedgerRecord(candidate: candidate, events: ledger.events))
        save()
        let decision: SuggestionGateDecision = gated
            ? try throttle.decide(at: now, shownOffsets: shownAutomaticOffsets(before: now))
            : .show
        switch decision {
        case .show:
            try ledger.append(SuggestionEvent(suggestionID: candidate.id, occurredAt: Date(), meetingOffset: now, kind: .shown))
            currentCardID = candidate.id
        case .suppress(let reason):
            try ledger.append(SuggestionEvent(suggestionID: candidate.id, occurredAt: Date(), meetingOffset: now, kind: .suppressed(reason: reason)))
        }
        ledgers[ledgers.count - 1].events = ledger.events
        save()
    }

    private func shownAutomaticOffsets(before now: TimeInterval) -> [TimeInterval] {
        ledgers.filter { $0.candidate.version.policy != "ask" }
            .flatMap(\.events)
            .filter { if case .shown = $0.kind { return true }; return false }
            .map(\.meetingOffset)
            .filter { $0 <= now }
    }

    // MARK: Card interactions

    func expandCurrentCard() { appendToCurrent(.expanded, closesCard: false) }
    func dismissCurrentCard() { appendToCurrent(.dismissed, closesCard: true) }
    func feedbackOnCurrentCard(useful: Bool) { appendToCurrent(.feedback(value: useful ? "useful" : "inaccurate"), closesCard: false) }

    private func appendToCurrent(_ kind: SuggestionEventKind, closesCard: Bool) {
        guard let id = currentCardID, let index = ledgers.firstIndex(where: { $0.candidate.id == id }) else { return }
        do {
            var ledger = try SuggestionLedger(candidate: ledgers[index].candidate, restoring: ledgers[index].events)
            let offset = max(elapsed(), ledger.events.last?.meetingOffset ?? 0)
            try ledger.append(SuggestionEvent(suggestionID: id, occurredAt: Date(), meetingOffset: offset, kind: kind))
            ledgers[index].events = ledger.events
            save()
        } catch {
            AppLog.generation.atError.error("MeetingCoachSession: card event rejected code=\(error.publicLogCode, privacy: .public)")
        }
        if closesCard { currentCardID = nil }
    }

    // MARK: Persistence and accounting

    private func account(model: String, _ usage: CoachTokenUsage) {
        cost.addTokens(model: model, usage: usage)
        updateBudget()
        save()
    }

    private func logTrigger(offset: TimeInterval, labels: [String], decision: String, reason: String) {
        triggerLog.append(CoachTriggerRecord(offset: offset, events: labels, decision: decision, reason: reason))
        save()
    }

    private func save() {
        guard let record else { return }
        record.segments = segments
        record.gaps = gaps
        record.ledgers = ledgers
        record.triggerLog = triggerLog
        record.costUSD += cost.totalUSD - savedLiveCost
        savedLiveCost = cost.totalUSD
        record.transcribedSeconds = cost.transcribedSeconds
        if let failure = modelContext.saveOrError() {
            AppLog.persistence.atError.error("MeetingCoachSession: save failed code=\(failure.logCode, privacy: .public)")
        }
    }
}
