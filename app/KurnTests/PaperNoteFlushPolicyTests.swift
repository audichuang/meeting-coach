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

        for _ in 0..<20 where harness.viewModel.paperNotes.hasUnsavedChanges {
            try await Task.sleep(for: .milliseconds(5))
        }
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

        for _ in 0..<20 where harness.viewModel.paperNotes.hasUnsavedChanges {
            try await Task.sleep(for: .milliseconds(5))
        }
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
            }
        )
        let recordingID = UUID()
        session.begin(recordingID: recordingID)

        // Write continuously every 300 ms (< 500 ms debounce) up to 4.8 s: debounce keeps resetting.
        var strokes: [PKStroke] = []
        for step in 0..<17 {
            strokes.append(contentsOf: makeSampleDrawing(offsetY: CGFloat(100 + step * 20)).strokes)
            session.drawingDidChange(PKDrawing(strokes: strokes))
            for _ in 0..<10 where clock.activeWaiterCount < 2 {
                await Task.yield()
            }
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
        for _ in 0..<50 where saveCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(saveCount == 1)
        #expect(!session.hasUnsavedChanges)
        let notesAfterFirst = try context.fetch(FetchDescriptor<PaperNote>(predicate: #Predicate { $0.recordingID == recordingID }))
        #expect(notesAfterFirst.first?.loadDrawing().strokes.count == 17)

        // Continue writing every 300 ms for another 5.0 s -> a second max-wait flush runs.
        for step in 0..<17 {
            strokes.append(contentsOf: makeSampleDrawing(offsetY: CGFloat(500 + step * 20)).strokes)
            session.drawingDidChange(PKDrawing(strokes: strokes))
            for _ in 0..<10 where clock.activeWaiterCount < 2 {
                await Task.yield()
            }
            if step < 16 {
                clock.advance(by: 0.3)
                await Task.yield()
            }
        }
        #expect(saveCount == 1)
        clock.advance(by: 0.2)
        for _ in 0..<50 where saveCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
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

        for _ in 0..<30 where viewModel.paperNotes.hasUnsavedChanges {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!viewModel.paperNotes.hasUnsavedChanges)
        let notes = try context.fetch(FetchDescriptor<PaperNote>())
        #expect(notes.count == 1)
        #expect(notes.first?.loadDrawing().strokes.count == 1)
    }
}
