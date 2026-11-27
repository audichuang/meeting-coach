import AVFoundation
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

private final class RecordingCoachLLM: CoachLLM, @unchecked Sendable {
    struct Call: Sendable {
        let tool: String
        let instructions: String
        let input: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] { lock.withLock { recorded } }

    func call(
        model: String,
        instructions: String,
        input: String,
        tools: [CoachTool],
        force: String?
    ) async throws -> CoachCallResult {
        let name = tools[0].name
        lock.withLock {
            recorded.append(Call(tool: name, instructions: instructions, input: input))
        }
        let args: String
        switch name {
        case "judge":
            args = #"{"decision":"emit","reason":"需要確認範圍"}"#
        case "emit_wrapup":
            args = #"{"common_goal":"g","disagreements":"d","open_questions":"o","next_steps":"n","spoken_text":"收尾"}"#
        default:
            args = #"{"short_text":"我們先對齊範圍？","reason":"範圍待確認","evidence_start":0,"evidence_end":20,"category":"clarify"}"#
        }
        return CoachCallResult(
            calls: [CoachToolCall(name: name, arguments: Data(args.utf8))],
            usage: CoachTokenUsage(input: 500, cached: 0, output: 50)
        )
    }
}

private actor StubLiveDiarizerEngine: LiveSpeakerDiarizerEngine {
    private var updates: [LiveDiarizerUpdate]
    private var finishUpdate: LiveDiarizerUpdate?
    private let finishError: (any Error)?
    private(set) var processedSampleCounts: [Int] = []
    private(set) var didCleanup = false

    init(updates: [LiveDiarizerUpdate], finishUpdate: LiveDiarizerUpdate? = nil, finishError: (any Error)? = nil) {
        self.updates = updates
        self.finishUpdate = finishUpdate
        self.finishError = finishError
    }

    func process(samples: [Float], sampleRate: Double) async throws -> LiveDiarizerUpdate? {
        processedSampleCounts.append(samples.count)
        guard !updates.isEmpty else { return nil }
        return updates.removeFirst()
    }

    func finish() async throws -> LiveDiarizerUpdate? {
        if let finishError { throw finishError }
        let next = finishUpdate
        finishUpdate = nil
        return next
    }

    func cleanup() async {
        didCleanup = true
    }
}

private actor TestGate {
    private var isOpen = false
    private(set) var isEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isEntered = true
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Emits one finalized span per non-silent chunk, timed by the samples it has been fed
/// (like Sortformer's own frame clock). The chunk's first sample encodes the slot: 0.1 -> 0, 0.2 -> 1.
private actor ClockStubDiarizerEngine: LiveSpeakerDiarizerEngine {
    private let firstProcessGate: TestGate?
    private var fedSamples = 0
    private var didGate = false

    init(firstProcessGate: TestGate? = nil) {
        self.firstProcessGate = firstProcessGate
    }

    func process(samples: [Float], sampleRate: Double) async throws -> LiveDiarizerUpdate? {
        if let firstProcessGate, !didGate {
            didGate = true
            await firstProcessGate.wait()
        }
        let start = Double(fedSamples) / sampleRate
        fedSamples += samples.count
        let end = Double(fedSamples) / sampleRate
        guard let first = samples.first, first != 0 else { return nil }
        let slot = Int((first * 10).rounded()) - 1
        return LiveDiarizerUpdate(
            finalized: [LiveSpeakerSpan(speakerSlot: slot, start: start, end: end)],
            tentative: [],
            finalizedThrough: end
        )
    }

    func finish() async throws -> LiveDiarizerUpdate? { nil }
    func cleanup() async {}
}

@MainActor
struct MeetingCoachSelfMarkTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeBuffer(sampleRate: Double = 24_000, frames: Int = 2_400, value: Float = 0.05) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.floatChannelData?[0] {
            for idx in 0..<frames { channel[idx] = value }
        }
        return buffer
    }

    private func waitForGate(_ gate: TestGate) async {
        for _ in 0..<300 where !(await gate.isEntered) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Appends `seconds` one-second buffers whose value encodes the speaker slot (see `ClockStubDiarizerEngine`).
    private func appendSeconds(_ seconds: Int, slotValue: Float, to service: LiveSpeakerDiarizationService) throws {
        for _ in 0..<seconds {
            service.append(try makeBuffer(frames: 24_000, value: slotValue))
        }
    }

    @Test func liveDiarizerSpansStayOnRecordingClockWhenAudioIsDroppedDuringModelLoad() async throws {
        let loadGate = TestGate()
        let stub = ClockStubDiarizerEngine()
        let service = LiveSpeakerDiarizationService(
            isInstalled: { true },
            engineFactory: {
                await loadGate.wait()
                return stub
            }
        )
        let starting = Task { await service.start() }
        await waitForGate(loadGate)

        // 20 s captured while the model loads: more than the 16 s queue holds.
        try appendSeconds(20, slotValue: 0.1, to: service)
        await loadGate.open()
        await starting.value
        #expect(service.isAvailable)

        try appendSeconds(1, slotValue: 0.2, to: service)
        await waitUntil { service.dominantSpeaker(from: 20, to: 21) != nil }

        #expect(service.dominantSpeaker(from: 20, to: 21) == "B")
        #expect(service.dominantSpeaker(from: 4, to: 20) == "A")
        #expect(service.dominantSpeaker(from: 0, to: 4) == nil)
        await service.stop(discarding: true)
    }

    @Test func liveDiarizerSpansStayOnRecordingClockWhenQueueOverflowsMidStream() async throws {
        let processGate = TestGate()
        let stub = ClockStubDiarizerEngine(firstProcessGate: processGate)
        let service = LiveSpeakerDiarizationService(isInstalled: { true }, engineFactory: { stub })
        await service.start()
        #expect(service.isAvailable)

        try appendSeconds(1, slotValue: 0.1, to: service)
        await waitForGate(processGate)
        // Inference stalls on the first second; 20 s more overflow the 16 s queue.
        try appendSeconds(20, slotValue: 0.2, to: service)
        await processGate.open()
        try appendSeconds(1, slotValue: 0.1, to: service)
        await waitUntil { service.dominantSpeaker(from: 21, to: 22) != nil }

        #expect(service.dominantSpeaker(from: 0, to: 1) == "A")
        #expect(service.dominantSpeaker(from: 1, to: 5) == nil)
        #expect(service.dominantSpeaker(from: 5, to: 21) == "B")
        #expect(service.dominantSpeaker(from: 21, to: 22) == "A")
        await service.stop(discarding: true)
    }

    @Test func liveDiarizerAssignsDominantLabelByOverlapAndCleansUp() async throws {
        let stub = StubLiveDiarizerEngine(
            updates: [
                LiveDiarizerUpdate(
                    finalized: [
                        LiveSpeakerSpan(speakerSlot: 0, start: 0, end: 5),
                        LiveSpeakerSpan(speakerSlot: 1, start: 5, end: 18)
                    ],
                    tentative: [
                        LiveSpeakerSpan(speakerSlot: 0, start: 18, end: 20)
                    ],
                    finalizedThrough: 20
                )
            ],
            finishUpdate: LiveDiarizerUpdate(
                finalized: [LiveSpeakerSpan(speakerSlot: 0, start: 18, end: 25)],
                tentative: [],
                finalizedThrough: 25
            )
        )
        let service = LiveSpeakerDiarizationService(
            isInstalled: { true },
            engineFactory: { stub }
        )
        var updatesReceived = 0
        await service.start(onUpdate: { updatesReceived += 1 })
        #expect(service.isAvailable)

        service.append(try makeBuffer())
        await waitUntil { updatesReceived >= 1 }

        #expect(service.dominantSpeaker(from: 0, to: 20) == "B")
        #expect(service.dominantSpeaker(from: 0, to: 5) == "A")

        var finishUpdates = 0
        await service.stop(discarding: false, onUpdate: { finishUpdates += 1 })
        #expect(!service.isAvailable)
        #expect(finishUpdates == 1)
        #expect(service.dominantSpeaker(from: 18, to: 25) == "A")
        #expect(await stub.didCleanup)
    }

    @Test func stopKeepsOnlyCoverageTheEngineFinalized() async throws {
        struct FinishFailure: Error {}
        let partial = LiveDiarizerUpdate(
            finalized: [LiveSpeakerSpan(speakerSlot: 0, start: 0, end: 8)],
            tentative: [LiveSpeakerSpan(speakerSlot: 0, start: 8, end: 20)],
            finalizedThrough: 8
        )
        for finish in [
            StubLiveDiarizerEngine(updates: [partial], finishError: FinishFailure()),
            // Backlog dropped at stop: finish() only finalizes what the engine was fed.
            StubLiveDiarizerEngine(
                updates: [partial],
                finishUpdate: LiveDiarizerUpdate(
                    finalized: [LiveSpeakerSpan(speakerSlot: 0, start: 8, end: 12)],
                    tentative: [],
                    finalizedThrough: 12
                )
            )
        ] {
            let service = LiveSpeakerDiarizationService(isInstalled: { true }, engineFactory: { finish })
            var updates = 0
            await service.start(onUpdate: { updates += 1 })
            service.append(try makeBuffer())
            await waitUntil { updates >= 1 }

            await service.stop(discarding: false)

            #expect(service.dominantSpeaker(from: 0, to: 8) == "A")
            #expect(service.dominantSpeaker(from: 0, to: 20) == nil)
        }
    }

    @Test func liveDiarizerReturnsNilWhenModelIsNotInstalled() async throws {
        nonisolated(unsafe) var factoryCalled = false
        let service = LiveSpeakerDiarizationService(
            isInstalled: { false },
            engineFactory: {
                factoryCalled = true
                return StubLiveDiarizerEngine(updates: [])
            }
        )

        await service.start()
        service.append(try makeBuffer())

        #expect(!service.isAvailable)
        #expect(!factoryCalled)
        #expect(service.dominantSpeaker(from: 0, to: 20) == nil)
        await service.stop()
    }

    @Test func liveDiarizerDegradesCleanlyWhenEngineLoadFails() async throws {
        struct LoadFailure: Error {}
        let service = LiveSpeakerDiarizationService(
            isInstalled: { true },
            engineFactory: { throw LoadFailure() }
        )

        await service.start()
        service.append(try makeBuffer())

        #expect(!service.isAvailable)
        #expect(service.dominantSpeaker(from: 0, to: 20) == nil)
        await service.stop()
    }

    #if canImport(FluidAudio)
    @Test func sortformerAvailabilityChecksCompiledManifestAndPartialFiles() {
        let dir = URL(fileURLWithPath: "/tmp/sortformer-test")
        let bundle = FluidAudioDiarizationModelRuntime.sortformerBundleName
        let manifest = dir.appendingPathComponent(bundle).appendingPathComponent("coremldata.bin").path

        #expect(!FluidAudioDiarizationModelRuntime.isSortformerInstalled(
            directory: dir,
            enumerate: { _ in nil },
            fileExists: { _ in false }
        ))
        #expect(!FluidAudioDiarizationModelRuntime.isSortformerInstalled(
            directory: dir,
            enumerate: { _ in ["coremldata.bin", "weights.bin.partial"] },
            fileExists: { $0 == manifest }
        ))
        #expect(FluidAudioDiarizationModelRuntime.isSortformerInstalled(
            directory: dir,
            enumerate: { _ in ["coremldata.bin", "weights.bin"] },
            fileExists: { $0 == manifest }
        ))
    }
    #endif

    @Test func markingAndUnmarkingUpdatesAllSegmentsOfThatLabelAndPersistsOnlyOnCurrentRecord() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Self Mark")
        context.insert(meeting)

        let session = MeetingCoachSession(
            meeting: meeting,
            modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "", budgetUSD: 10, backend: .test),
            llm: RecordingCoachLLM(),
            speakerLookup: { start, _ in start < 20 || start >= 40 ? "A" : "B" },
            elapsed: { 65 }
        )
        let recordingID = UUID()
        session.begin(recordingID: recordingID)
        session.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "第一段", arrivedAt: 20)))
        session.eventSink.yield(.final(LiveTranscriptSegment(start: 20, end: 40, text: "第二段", arrivedAt: 40)))
        session.eventSink.yield(.final(LiveTranscriptSegment(start: 40, end: 60, text: "第三段", arrivedAt: 60)))
        await waitUntil { session.segments.count == 3 }

        #expect(session.segments.map(\.speakerLabel) == ["A", "B", "A"])
        #expect(session.selfSpeakerLabel == nil)

        // Mark A -> both A segments become self; B stays B.
        session.markSelfSpeaker("A")
        let markedPresentations = session.segments.map {
            LiveTranscriptSegmentPresentation(segment: $0, selfSpeakerLabel: session.selfSpeakerLabel)
        }
        #expect(markedPresentations.map(\.isSelf) == [true, false, true])
        #expect(markedPresentations[0].badgeText == NSLocalizedString("coach.speaker.self", comment: ""))
        #expect(markedPresentations[1].badgeText == "B")
        #expect(markedPresentations[2].badgeText == NSLocalizedString("coach.speaker.self", comment: ""))
        #expect(markedPresentations[0].menuActionTitle == NSLocalizedString("coach.speaker.not_me", comment: ""))
        #expect(markedPresentations[1].menuActionTitle == NSLocalizedString("coach.speaker.this_is_me", comment: ""))

        // Persisted on the CoachRecord and survives crash/restore of this recording.
        let persisted = try #require(try context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(persisted.selfSpeakerLabel == "A")

        let restored = MeetingCoachSession(
            meeting: meeting,
            modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "", budgetUSD: 10, backend: .test),
            llm: RecordingCoachLLM(),
            elapsed: { 70 }
        )
        restored.begin(recordingID: recordingID)
        #expect(restored.selfSpeakerLabel == "A")
        #expect(restored.segments.count == 3)
        await restored.finish(at: 70)

        // Re-marking to B switches all A back to A and B to self.
        session.markSelfSpeaker("B")
        let remarked = session.segments.map {
            LiveTranscriptSegmentPresentation(segment: $0, selfSpeakerLabel: session.selfSpeakerLabel)
        }
        #expect(remarked.map(\.isSelf) == [false, true, false])
        #expect(remarked[0].badgeText == "A")
        #expect(remarked[1].badgeText == NSLocalizedString("coach.speaker.self", comment: ""))

        // Clearing resets all labels back to anonymous letters.
        session.clearSelfSpeaker()
        let cleared = session.segments.map {
            LiveTranscriptSegmentPresentation(segment: $0, selfSpeakerLabel: session.selfSpeakerLabel)
        }
        #expect(cleared.map(\.isSelf) == [false, false, false])
        #expect(cleared.map(\.badgeText) == ["A", "B", "A"])
        #expect(persisted.selfSpeakerLabel == nil)

        // Re-mark A, then start a brand-new meeting: self label must NOT carry over.
        session.markSelfSpeaker("A")
        await session.finish(at: 70)

        let nextMeeting = Meeting(title: "Next Meeting")
        context.insert(nextMeeting)
        let nextSession = MeetingCoachSession(
            meeting: nextMeeting,
            modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "", budgetUSD: 10, backend: .test),
            llm: RecordingCoachLLM(),
            elapsed: { 10 }
        )
        nextSession.begin(recordingID: UUID())
        #expect(nextSession.selfSpeakerLabel == nil)
        await nextSession.finish(at: 10)
    }

    @Test func labelsAndSelfMarkActionAreHiddenWhenDiarizerIsUnavailable() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "No Diarizer")
        context.insert(meeting)

        let session = MeetingCoachSession(
            meeting: meeting,
            modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "", budgetUSD: 10, backend: .test),
            llm: RecordingCoachLLM(),
            speakerLookup: { _, _ in nil },
            elapsed: { 25 }
        )
        session.begin(recordingID: UUID())
        session.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "先對齊排程", arrivedAt: 20)))
        await waitUntil { session.segments.count == 1 }

        #expect(session.segments[0].speakerLabel == nil)
        let presentation = LiveTranscriptSegmentPresentation(
            segment: session.segments[0],
            selfSpeakerLabel: session.selfSpeakerLabel
        )
        #expect(presentation.badgeText == nil)
        #expect(!presentation.canMarkSelf)
        #expect(presentation.menuActionTitle == nil)
        await session.finish(at: 25)
    }

    @Test func suggestionPipelineRendersMarkedSpeakerAsUserAcrossGateCardAskAndWrapUp() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Pipeline Self Mark")
        context.insert(meeting)
        let llm = RecordingCoachLLM()

        let session = MeetingCoachSession(
            meeting: meeting,
            modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "", budgetUSD: 10, backend: .test),
            llm: llm,
            speakerLookup: { start, _ in start < 140 ? "A" : "B" },
            elapsed: { 160 }
        )
        session.begin(recordingID: UUID())
        session.eventSink.yield(.final(LiveTranscriptSegment(start: 120, end: 140, text: "我建議先交付核心流程。", arrivedAt: 140)))
        await waitUntil { session.segments.count == 1 }
        session.markSelfSpeaker("A")

        session.eventSink.yield(.final(LiveTranscriptSegment(start: 140, end: 160, text: "那下週要一起上線嗎？", arrivedAt: 160)))
        await waitUntil { llm.calls.contains { $0.tool == "emit_suggestion" } }

        await session.askForCard()
        await session.requestWrapUp()
        await session.finish(at: 165)

        let judgeCall = try #require(llm.calls.first { $0.tool == "judge" })
        let cardCalls = llm.calls.filter { $0.tool == "emit_suggestion" }
        let wrapCall = try #require(llm.calls.first { $0.tool == "emit_wrapup" })

        #expect(cardCalls.count == 2)
        for call in [judgeCall, wrapCall] + cardCalls {
            #expect(call.input.contains("[120–140] 使用者: 我建議先交付核心流程。"))
            #expect(call.input.contains("[140–160] B: 那下週要一起上線嗎？"))
        }
        #expect(cardCalls[0].instructions.contains("使用者"))
        #expect(cardCalls[0].instructions.contains("不要重述使用者"))
    }

    @Test func refreshUnlabeledSegmentsBackfillsNilLabelsWithoutOverwritingExistingOnes() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Backfill")
        context.insert(meeting)

        let lock = NSLock()
        nonisolated(unsafe) var lookupResult: [TimeInterval: String] = [20: "B"]
        let session = MeetingCoachSession(
            meeting: meeting,
            modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "", budgetUSD: 10, backend: .test),
            llm: RecordingCoachLLM(),
            speakerLookup: { start, _ in lock.withLock { lookupResult[start] } },
            elapsed: { 45 }
        )
        session.begin(recordingID: UUID())
        session.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "第一段", arrivedAt: 20)))
        session.eventSink.yield(.final(LiveTranscriptSegment(start: 20, end: 40, text: "第二段", arrivedAt: 40)))
        await waitUntil { session.segments.count == 2 }

        #expect(session.segments.map(\.speakerLabel) == [nil, "B"])

        lock.withLock {
            lookupResult[0] = "A"
            lookupResult[20] = "C" // must not overwrite existing "B"
        }
        session.refreshUnlabeledSegments()

        #expect(session.segments.map(\.speakerLabel) == ["A", "B"])
        let record = try #require(try context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(record.segments.map(\.speakerLabel) == ["A", "B"])
        await session.finish(at: 45)
    }

    @Test func segmentLabelWaitsForFinalizedCoverageThenBackfillsDominantSpeaker() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Coverage")
        context.insert(meeting)

        let stub = StubLiveDiarizerEngine(updates: [
            // Frames are final only through 8 s; the tentative tail still guesses slot 0.
            LiveDiarizerUpdate(
                finalized: [LiveSpeakerSpan(speakerSlot: 0, start: 0, end: 8)],
                tentative: [LiveSpeakerSpan(speakerSlot: 0, start: 8, end: 20)],
                finalizedThrough: 8
            ),
            LiveDiarizerUpdate(
                finalized: [LiveSpeakerSpan(speakerSlot: 1, start: 8, end: 20)],
                tentative: [],
                finalizedThrough: 20
            )
        ])
        let service = LiveSpeakerDiarizationService(isInstalled: { true }, engineFactory: { stub })
        let session = MeetingCoachSession(
            meeting: meeting,
            modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "", budgetUSD: 10, backend: .test),
            llm: RecordingCoachLLM(),
            speakerLookup: { [service] start, end in service.dominantSpeaker(from: start, to: end) },
            elapsed: { 25 }
        )
        session.begin(recordingID: UUID())
        var updates = 0
        await service.start(onUpdate: {
            updates += 1
            session.refreshUnlabeledSegments()
        })

        service.append(try makeBuffer())
        await waitUntil { updates >= 1 }
        session.eventSink.yield(.final(LiveTranscriptSegment(start: 0, end: 20, text: "第一段", arrivedAt: 20)))
        await waitUntil { session.segments.count == 1 }
        #expect(session.segments[0].speakerLabel == nil)

        service.append(try makeBuffer())
        await waitUntil { updates >= 2 }
        // A: 8 s, B: 12 s once every frame of the segment is final.
        #expect(session.segments[0].speakerLabel == "B")

        await service.stop(discarding: true)
        await session.finish(at: 25)
    }

    @Test func v6StoreMigratesCleanlyToV7AndPersistsSelfSpeakerLabel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaV6ToV7Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("v6.store")

        let recordingID = UUID()
        do {
            let v6Schema = Schema(versionedSchema: KurnSchemaV6.self)
            let v6Container = try ModelContainer(
                for: v6Schema,
                configurations: [ModelConfiguration(schema: v6Schema, url: storeURL)]
            )
            let v6Context = v6Container.mainContext
            let meeting = KurnSchemaV6.Meeting(title: "V6 Meeting", languageRaw: MeetingLanguage.autoDetect.rawValue)
            v6Context.insert(meeting)
            let coachRecord = KurnSchemaV6.CoachRecord(meeting: meeting, recordingID: recordingID, userName: "使用者")
            v6Context.insert(coachRecord)
            v6Context.insert(KurnSchemaV6.PaperNote(meeting: meeting, recordingID: recordingID, strokeCount: 2))
            try v6Context.save()
        }

        let v7Container = try ModelContainer(
            for: KurnModelGraph.schema,
            migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)]
        )
        let v7Context = v7Container.mainContext
        let migrated = try #require(try v7Context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(migrated.recordingID == recordingID)
        #expect(migrated.selfSpeakerLabel == nil)
        migrated.selfSpeakerLabel = "B"
        try v7Context.save()

        let reloaded = try #require(try v7Context.fetch(FetchDescriptor<CoachRecord>()).first)
        #expect(reloaded.selfSpeakerLabel == "B")
        let notes = try v7Context.fetch(FetchDescriptor<PaperNote>())
        #expect(notes.first?.strokeCount == 2)
    }

    @Test func speakerModelInstalledStateDrivesCoachHintAndSettingsRow() async throws {
        // 1. Presentation of the hint above the live transcript.
        let hintWhenMissing = MeetingCoachSpeakerHintPresentation.hintText(
            isModelInstalled: false,
            hasLabeledSegments: false
        )
        #expect(hintWhenMissing == NSLocalizedString("coach.speaker.download_hint", comment: ""))
        #expect(MeetingCoachSpeakerHintPresentation.hintText(isModelInstalled: true, hasLabeledSegments: false) == nil)
        #expect(MeetingCoachSpeakerHintPresentation.hintText(isModelInstalled: false, hasLabeledSegments: true) == nil)

        // 2. Presentation of the Settings row across not-installed, downloading, and installed states.
        let notInstalledRow = MeetingCoachSpeakerModelRowPresentation(
            isInstalled: false,
            installedBytes: 0,
            isDownloadingThis: false,
            isAnyDownloading: false
        )
        #expect(notInstalledRow.title == NSLocalizedString("settings.coach.speaker_model", comment: ""))
        #expect(notInstalledRow.detailText == NSLocalizedString("settings.coach.speaker_model_not_installed", comment: ""))
        #expect(notInstalledRow.showsDownloadButton && notInstalledRow.isDownloadEnabled)
        #expect(!notInstalledRow.showsProgress && !notInstalledRow.showsDeleteButton)

        let downloadingRow = MeetingCoachSpeakerModelRowPresentation(
            isInstalled: false,
            installedBytes: 0,
            isDownloadingThis: true,
            isAnyDownloading: true
        )
        #expect(!downloadingRow.showsDownloadButton && !downloadingRow.showsDeleteButton)
        #expect(downloadingRow.showsProgress)

        let installedBytes: Int64 = 28_500_000
        let installedRow = MeetingCoachSpeakerModelRowPresentation(
            isInstalled: true,
            installedBytes: installedBytes,
            isDownloadingThis: false,
            isAnyDownloading: false
        )
        #expect(installedRow.detailText == AudioFileStore.formattedSize(installedBytes))
        #expect(!installedRow.showsDownloadButton && !installedRow.showsProgress)
        #expect(installedRow.showsDeleteButton && installedRow.isDeleteEnabled)

        // 3. ModelDownloadController + MeetingCoachSession react to download and delete.
        let suiteName = "MeetingCoachSelfMarkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)

        nonisolated(unsafe) var installed = false
        nonisolated(unsafe) var diskBytes: Int64 = 0
        nonisolated(unsafe) var downloadedSets: [ModelSet] = []
        nonisolated(unsafe) var deleted = false

        let controller = ModelDownloadController(
            downloader: { set, _, onProgress in
                downloadedSets.append(set)
                onProgress(ModelDownloadStatus(fractionCompleted: 0.5, phase: .downloading))
                installed = true
                diskBytes = installedBytes
                onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
            },
            isStreamingDiarizationInstalled: { installed },
            streamingDiarizationSizeBytes: { diskBytes },
            deleteStreamingDiarizationFiles: {
                deleted = true
                installed = false
                diskBytes = 0
            }
        )

        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Hint Toggle")
        context.insert(meeting)
        let session = MeetingCoachSession(
            meeting: meeting,
            modelContext: context,
            configuration: MeetingCoachConfiguration(userName: "", budgetUSD: 10, backend: .test),
            llm: RecordingCoachLLM(),
            isSpeakerModelInstalled: { installed },
            elapsed: { 0 }
        )

        #expect(!controller.isStreamingDiarizationReady)
        #expect(controller.streamingDiarizationBytes == 0)
        #expect(!session.isSpeakerModelInstalled)

        controller.requestStreamingDiarizationDownload()
        #expect(controller.showingStreamingDiarizationConsent)
        controller.confirmStreamingDiarization(settings: settings)
        await waitUntil { !controller.isDownloading }

        #expect(downloadedSets == [.streamingDiarization])
        #expect(controller.isStreamingDiarizationReady)
        #expect(controller.streamingDiarizationBytes == installedBytes)
        session.refreshSpeakerModelAvailability()
        #expect(session.isSpeakerModelInstalled)

        controller.requestDeleteStreamingDiarization()
        #expect(controller.showingStreamingDiarizationDeleteConfirm)
        controller.confirmDeleteStreamingDiarization()

        #expect(deleted)
        #expect(!controller.isStreamingDiarizationReady)
        #expect(controller.streamingDiarizationBytes == 0)
        session.refreshSpeakerModelAvailability()
        #expect(!session.isSpeakerModelInstalled)
    }
}
