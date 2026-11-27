//
//  PaperNoteFlushPolicyTests.swift
//  KurnTests
//
//  Verifies bounded flush guarantees for `PaperNoteSession`: max-wait under
//  continuous writing (via an injectable `SleepClock`), flushing on pause
//  (both UI toggle and Watch/system pause), and flushing on scene background.
//

import CoreGraphics
import Foundation
import KurnCore
import PencilKit
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct PaperNoteFlushPolicyTests {

    private func makeSampleDrawing(offsetY: CGFloat = 180) -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 96, y: offsetY),
                timeOffset: 0,
                size: CGSize(width: 4, height: 4),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 340, y: offsetY + 24),
                timeOffset: 0.12,
                size: CGSize(width: 4, height: 4),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_760_000_000))
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)
        return PKDrawing(strokes: [stroke])
    }

    private struct RecorderHarness {
        let container: ModelContainer
        let context: ModelContext
        let meeting: Meeting
        let recorder: AudioRecorderService
        let viewModel: RecorderViewModel
    }

    private func makeRecorderHarness() throws -> RecorderHarness {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Flush Policy")
        context.insert(meeting)
        try context.save()
        let recorder = AudioRecorderService(
            engine: FakeAudioCaptureEngine(),
            sink: FakeAudioSinkWriting(),
            stallInterval: 3_600,
            microphonePermission: { true }
        )
        let viewModel = RecorderViewModel(
            meeting: meeting,
            modelContext: context,
            defaultMode: .onDevice,
            options: RecorderOptions(alwaysUseBuiltInMic: true),
            recorder: recorder,
            fileFinalizer: StubRecordingFileFinalizer(result: FinalizedRecordingFile(duration: 4, fileSize: 2_048)),
            lifecycleSaver: ScriptedRecordingLifecycleSaver()
        )
        return RecorderHarness(container: container, context: context, meeting: meeting, recorder: recorder, viewModel: viewModel)
    }

    @Test func togglePauseFlushesUnsavedPaperNotesBeforeDebounceExpires() async throws {
        let harness = try makeRecorderHarness()
        defer { harness.viewModel.cancel() }

        await harness.viewModel.startRecording()
        harness.viewModel.paperNotes.drawingDidChange(makeSampleDrawing())
        #expect(harness.viewModel.paperNotes.hasUnsavedChanges)

        harness.viewModel.togglePause()
        await harness.viewModel.paperNotes.waitForInFlightFlush()
        #expect(!harness.viewModel.paperNotes.hasUnsavedChanges)
        let notes = try harness.context.fetch(FetchDescriptor<PaperNote>())
        #expect(notes.count == 1)
        #expect(notes.first?.loadDrawing().strokes.count == 1)
    }

    @Test func watchPauseFlushesUnsavedPaperNotesBeforeDebounceExpires() async throws {
        let harness = try makeRecorderHarness()
        defer { harness.viewModel.cancel() }

        await harness.viewModel.startRecording()
        harness.viewModel.paperNotes.drawingDidChange(makeSampleDrawing())
        #expect(harness.viewModel.paperNotes.hasUnsavedChanges)

        harness.recorder.pause(reason: .watchCommand)
        await harness.viewModel.paperNotes.waitForInFlightFlush()
        #expect(!harness.viewModel.paperNotes.hasUnsavedChanges)
        let notes = try harness.context.fetch(FetchDescriptor<PaperNote>())
        #expect(notes.count == 1)
    }

    @Test func continuousWritingFlushesAtMaxWaitIntervalUsingInjectableClock() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Continuous Writing")
        context.insert(meeting)
        try context.save()

        let clock = VirtualSleepClock()
        let serializeStarted = AsyncStream<Void>.makeStream()
        var startedIterator = serializeStarted.stream.makeAsyncIterator()
        var saveCount = 0
        let session = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(500),
            maxWaitInterval: .seconds(5),
            sleepClock: clock,
            elapsed: { 10 },
            persist: { ctx in
                saveCount += 1
                return ctx.saveOrError()
            },
            serialize: { snapshot in
                serializeStarted.continuation.yield(())
                return await PaperNoteSession.serializeOffMain(snapshot)
            }
        )
        let recordingID = UUID()
        session.begin(recordingID: recordingID)

        // Write continuously every 300 ms (< 500 ms debounce) up to 4.8 s: debounce keeps resetting.
        var strokes: [PKStroke] = []
        for step in 0..<17 {
            strokes.append(contentsOf: makeSampleDrawing(offsetY: CGFloat(100 + step * 20)).strokes)
            session.drawingDidChange(PKDrawing(strokes: strokes))
            await clock.waitForWaiters(atLeast: 2)
            if step < 16 {
                clock.advance(by: 0.3)
                await Task.yield()
            }
        }
        // At t = 4.8 s, debounce never expired and max-wait (5.0 s) has not elapsed yet.
        #expect(saveCount == 0)
        #expect(session.hasUnsavedChanges)

        // Advancing 0.2 s reaches 5.0 s -> max-wait fires and persists all 17 strokes.
        clock.advance(by: 0.2)
        _ = await startedIterator.next()
        await session.waitForInFlightFlush()
        #expect(saveCount == 1)
        #expect(!session.hasUnsavedChanges)
        let notesAfterFirst = try context.fetch(FetchDescriptor<PaperNote>(predicate: #Predicate { $0.recordingID == recordingID }))
        #expect(notesAfterFirst.first?.loadDrawing().strokes.count == 17)

        // Continue writing every 300 ms for another 5.0 s -> a second max-wait flush runs.
        for step in 0..<17 {
            strokes.append(contentsOf: makeSampleDrawing(offsetY: CGFloat(500 + step * 20)).strokes)
            session.drawingDidChange(PKDrawing(strokes: strokes))
            await clock.waitForWaiters(atLeast: 2)
            if step < 16 {
                clock.advance(by: 0.3)
                await Task.yield()
            }
        }
        #expect(saveCount == 1)
        clock.advance(by: 0.2)
        _ = await startedIterator.next()
        await session.waitForInFlightFlush()
        #expect(saveCount == 2)
        #expect(!session.hasUnsavedChanges)
        let notesAfterSecond = try context.fetch(FetchDescriptor<PaperNote>(predicate: #Predicate { $0.recordingID == recordingID }))
        #expect(notesAfterSecond.first?.loadDrawing().strokes.count == 34)
    }

    @Test func sceneBackgroundFlushesUnsavedPaperNotesThroughRecordingSessionController() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Background Flush")
        context.insert(meeting)
        try context.save()

        let controller = RecordingSessionController(
            modelContext: context,
            settings: AppSettings(),
            makeViewModel: { meeting, ctx in
                RecorderViewModel(
                    meeting: meeting,
                    modelContext: ctx,
                    defaultMode: .onDevice,
                    options: RecorderOptions(alwaysUseBuiltInMic: true),
                    recorder: AudioRecorderService(
                        engine: FakeAudioCaptureEngine(),
                        sink: FakeAudioSinkWriting(),
                        stallInterval: 3_600,
                        microphonePermission: { true }
                    ),
                    fileFinalizer: StubRecordingFileFinalizer(result: FinalizedRecordingFile(duration: 4, fileSize: 2_048)),
                    lifecycleSaver: ScriptedRecordingLifecycleSaver()
                )
            },
            prepare: { _ in }
        )
        defer { controller.discard() }

        controller.begin(meeting: meeting)
        let viewModel = try #require(controller.viewModel)
        await viewModel.startRecording()

        viewModel.paperNotes.drawingDidChange(makeSampleDrawing())
        #expect(viewModel.paperNotes.hasUnsavedChanges)

        controller.handleSceneDidEnterBackground()

        for _ in 0..<200 where viewModel.paperNotes.hasUnsavedChanges {
            await Task.yield()
            await viewModel.paperNotes.waitForInFlightFlush()
        }
        #expect(!viewModel.paperNotes.hasUnsavedChanges)
        let notes = try context.fetch(FetchDescriptor<PaperNote>())
        #expect(notes.count == 1)
        #expect(notes.first?.loadDrawing().strokes.count == 1)
    }

    @Test func failedSaveDuringInFlightBackgroundFlushRetriesAndPersistsFollowUpStroke() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Failed Save Follow-Up")
        context.insert(meeting)
        try context.save()

        let sleepClock = VirtualSleepClock()
        let gate = GatedDrawingSerializer()
        var persistAttempts = 0
        let recordingID = UUID()

        let session = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(500),
            maxWaitInterval: .seconds(5),
            sleepClock: sleepClock,
            elapsed: { 15 },
            persist: { ctx in
                persistAttempts += 1
                if persistAttempts == 1 {
                    return .persistenceFailed("simulated transient disk error")
                }
                return ctx.saveOrError()
            },
            serialize: { snapshot in await gate.serialize(snapshot) }
        )
        session.begin(recordingID: recordingID)

        // Snapshot A starts serializing in flight via debounce; max-wait fires while A is still in flight.
        let strokeA = makeSampleDrawing(offsetY: 120)
        session.drawingDidChange(strokeA)
        await sleepClock.waitForWaiters(atLeast: 2)
        sleepClock.advance(by: 0.5)
        await gate.waitForCall(atLeast: 1)

        // Stroke B arrives while A is in flight; max-wait expires and background flush sets needsFollowUpFlush.
        let strokeB = PKDrawing(strokes: strokeA.strokes + makeSampleDrawing(offsetY: 240).strokes)
        session.drawingDidChange(strokeB)
        sleepClock.advance(by: 4.5)
        let backgroundFlushTask = try #require(session.flushForBackground())
        for _ in 0..<20 where sleepClock.activeWaiterCount > 0 {
            await Task.yield()
        }
        #expect(sleepClock.activeWaiterCount == 0)

        // Release A: its save fails. Background flush reports failure, B stays pending and schedules bounded retry.
        gate.releaseNext()
        let firstFlushSucceeded = await backgroundFlushTask.value
        #expect(!firstFlushSucceeded)
        #expect(session.lastSaveError != nil)
        #expect(persistAttempts == 1)
        #expect(session.hasUnsavedChanges)

        // Advance virtual clock through retry backoff so B is serialized and saved.
        await sleepClock.waitForWaiters(atLeast: 1)
        sleepClock.advance(by: 1.0)
        await gate.waitForCall(atLeast: 2)
        gate.releaseNext()
        await session.waitForInFlightFlush()

        #expect(persistAttempts == 2)
        #expect(!session.hasUnsavedChanges)
        #expect(session.lastSaveError == nil)
        let saved = try #require(
            try context.fetch(FetchDescriptor<PaperNote>(predicate: #Predicate { $0.recordingID == recordingID })).first
        )
        #expect(saved.loadDrawing().strokes.count == 2)

        // A subsequent background flush with a new stroke reports success.
        let strokeC = PKDrawing(strokes: strokeB.strokes + makeSampleDrawing(offsetY: 360).strokes)
        session.drawingDidChange(strokeC)
        let secondFlushTask = try #require(session.flushForBackground())
        await gate.waitForCall(atLeast: 3)
        gate.releaseNext()
        #expect(await secondFlushTask.value)
        #expect(!session.hasUnsavedChanges)
    }

    @Test func persistentSaveFailuresStopAfterBoundedRetryBudget() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Bounded Retry")
        context.insert(meeting)
        try context.save()

        let sleepClock = VirtualSleepClock()
        let gate = GatedDrawingSerializer()
        var attempts = 0
        let session = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(500),
            maxWaitInterval: .seconds(5),
            retryBaseInterval: .seconds(1),
            maxAutomaticRetries: 2,
            sleepClock: sleepClock,
            elapsed: { 5 },
            persist: { _ in
                attempts += 1
                return .persistenceFailed("disk full")
            },
            serialize: { snapshot in await gate.serialize(snapshot) }
        )
        session.begin(recordingID: UUID())
        session.drawingDidChange(makeSampleDrawing())

        // Initial flush fails -> retry #1 scheduled (1s).
        let flushTask = Task { await session.flush() }
        await gate.waitForCall(atLeast: 1)
        gate.releaseNext()
        let ok = await flushTask.value
        #expect(!ok)
        #expect(attempts == 1)
        await sleepClock.waitForWaiters(atLeast: 1)

        // Retry #1 fails -> retry #2 scheduled (2s).
        sleepClock.advance(by: 1.0)
        await gate.waitForCall(atLeast: 2)
        gate.releaseNext()
        await session.waitForInFlightFlush()
        #expect(attempts == 2)
        await sleepClock.waitForWaiters(atLeast: 1)

        // Retry #2 fails -> budget exhausted (maxAutomaticRetries == 2), no further retries scheduled.
        sleepClock.advance(by: 2.0)
        await gate.waitForCall(atLeast: 3)
        gate.releaseNext()
        await session.waitForInFlightFlush()
        #expect(attempts == 3)
        #expect(sleepClock.activeWaiterCount == 0)
        #expect(session.hasUnsavedChanges)
        #expect(session.lastSaveError != nil)
    }

    @Test func finishWhileSerializationInFlightWaitsAndSerializesLatestOffMainWithoutConcurrency() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Finish Off-Main")
        context.insert(meeting)
        try context.save()

        let gate = GatedDrawingSerializer()
        let recordingID = UUID()
        var elapsed: TimeInterval = 20
        let session = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(500),
            elapsed: { elapsed },
            serialize: { snapshot in await gate.serialize(snapshot) }
        )
        session.begin(recordingID: recordingID)

        // Snapshot A starts serializing off-main and pauses at the gate.
        let strokeA = makeSampleDrawing(offsetY: 120)
        session.drawingDidChange(strokeA)
        session.requestFlush()
        await gate.waitForCall(atLeast: 1)

        // Stroke B arrives while A is still in flight.
        elapsed = 55
        let strokeB = PKDrawing(strokes: strokeA.strokes + makeSampleDrawing(offsetY: 260).strokes)
        session.drawingDidChange(strokeB)

        // Finishing must wait for A instead of cancelling A and encoding B on MainActor.
        let finishTask = Task { await session.finish() }
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(gate.callCount == 1, "Must wait for A before starting B")
        #expect(gate.maxConcurrent == 1)
        #expect(gate.hasWaitingCall)

        // Release A -> A commits, then B starts off-main (still never two concurrent).
        gate.releaseNext()
        await gate.waitForCall(atLeast: 2)
        #expect(gate.maxConcurrent == 1)

        // Release B -> finish completes cleanly off-main with both batches persisted.
        gate.releaseNext()
        let finished = await finishTask.value
        #expect(finished)
        #expect(gate.callCount == 2)
        #expect(gate.maxConcurrent == 1)
        #expect(gate.ranOffMainThread)
        #expect(!session.hasUnsavedChanges)

        let saved = try #require(
            try context.fetch(FetchDescriptor<PaperNote>(predicate: #Predicate { $0.recordingID == recordingID })).first
        )
        #expect(saved.loadDrawing().strokes.count == 2)
        try #require(saved.anchors.count == 2)
        #expect(saved.anchors[0].recordingOffset == 20)
        #expect(saved.anchors[0].strokeCount == 1)
        #expect(saved.anchors[1].recordingOffset == 55)
        #expect(saved.anchors[1].strokeCount == 2)
    }

    @Test func stopAndSaveDoesNotBlockOnInFlightPaperSerializationAndPersistsLatestOffMain() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Non-Blocking Stop")
        context.insert(meeting)
        try context.save()

        let gate = GatedDrawingSerializer()
        let recorder = AudioRecorderService(
            engine: FakeAudioCaptureEngine(),
            sink: FakeAudioSinkWriting(),
            stallInterval: 3_600,
            microphonePermission: { true }
        )
        let paperNotes = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            elapsed: { [weak recorder] in recorder?.elapsed ?? 0 },
            serialize: { snapshot in await gate.serialize(snapshot) }
        )
        let viewModel = RecorderViewModel(
            meeting: meeting,
            modelContext: context,
            defaultMode: .onDevice,
            options: RecorderOptions(alwaysUseBuiltInMic: true),
            recorder: recorder,
            paperNoteSession: paperNotes,
            fileFinalizer: StubRecordingFileFinalizer(result: FinalizedRecordingFile(duration: 4, fileSize: 2_048)),
            lifecycleSaver: ScriptedRecordingLifecycleSaver()
        )

        await viewModel.startRecording()
        let strokeA = makeSampleDrawing(offsetY: 120)
        paperNotes.drawingDidChange(strokeA)
        paperNotes.requestFlush()
        await gate.waitForCall(atLeast: 1)

        let strokeB = PKDrawing(strokes: strokeA.strokes + makeSampleDrawing(offsetY: 260).strokes)
        paperNotes.drawingDidChange(strokeB)

        // Recording stop returns immediately while A is still paused at the gate.
        let finalized = viewModel.stopAndSave()
        #expect(finalized)
        #expect(viewModel.didSaveRecording)
        #expect(gate.callCount == 1)
        #expect(gate.hasWaitingCall)

        // Releasing A triggers off-main serialization of B, never overlapping.
        gate.releaseNext()
        await gate.waitForCall(atLeast: 2)
        #expect(gate.maxConcurrent == 1)
        gate.releaseNext()
        await paperNotes.waitForInFlightFlush()

        #expect(!paperNotes.hasUnsavedChanges)
        #expect(gate.callCount == 2)
        #expect(gate.maxConcurrent == 1)
        #expect(gate.ranOffMainThread)
        let notes = try context.fetch(FetchDescriptor<PaperNote>())
        #expect(notes.count == 1)
        #expect(notes.first?.loadDrawing().strokes.count == 2)
    }
}
