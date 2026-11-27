//
//  PaperNoteTests.swift
//  KurnTests
//
//  Covers `PaperNote` persistence, `PaperNoteSession` debounced saving and
//  recording-offset anchors, deletion alongside recordings (`MeetingLibrary`
//  and `LibraryEraser`), `PaperCanvasMetrics` page-coordinate transforms, and
//  SwiftData migration from `KurnSchemaV5` (1.4.0) to `KurnSchemaV6` (1.5.0).
//

import CoreGraphics
import Foundation
import KurnCore
import PencilKit
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Kurn

@MainActor
struct PaperNoteTests {

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

    // MARK: - Persistence & Reload

    @Test func debouncedSavePersistsAndReloadsDrawingWithAnchors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperNoteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("paper.store")

        let recordingID = UUID()
        var clock = Date(timeIntervalSince1970: 1_760_000_000)
        var elapsed: TimeInterval = 42.5
        let expectedDrawing = makeSampleDrawing()

        do {
            let container = try ModelContainer(
                for: KurnModelGraph.schema,
                migrationPlan: KurnModelGraph.migrationPlan,
                configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)]
            )
            let context = container.mainContext
            let meeting = Meeting(title: "Design Review")
            context.insert(meeting)
            let recording = Recording(id: recordingID, meeting: meeting, fileName: "rec.m4a", duration: 60)
            context.insert(recording)
            try context.save()

            let sleepClock = VirtualSleepClock()
            let serializeStarted = AsyncStream<Void>.makeStream()
            let session = PaperNoteSession(
                meeting: meeting,
                modelContext: context,
                debounceInterval: .milliseconds(30),
                sleepClock: sleepClock,
                elapsed: { elapsed },
                now: { clock },
                serialize: { snapshot in
                    serializeStarted.continuation.yield(())
                    return await PaperNoteSession.serializeOffMain(snapshot)
                }
            )
            session.begin(recordingID: recordingID)
            session.drawingDidChange(expectedDrawing)
            #expect(session.hasUnsavedChanges)

            await sleepClock.waitForWaiters(atLeast: 2)
            sleepClock.advance(by: 0.03)
            var startedIterator = serializeStarted.stream.makeAsyncIterator()
            _ = await startedIterator.next()
            await session.waitForInFlightFlush()
            #expect(!session.hasUnsavedChanges)
            #expect(session.lastSavedAt == clock)

            // A second stroke batch updates the same PaperNote row and advances updatedAt.
            clock = Date(timeIntervalSince1970: 1_760_000_050)
            elapsed = 92.5
            let twoStrokeDrawing = PKDrawing(strokes: expectedDrawing.strokes + makeSampleDrawing(offsetY: 260).strokes)
            session.drawingDidChange(twoStrokeDrawing)
            session.finish()

            #expect(!session.hasUnsavedChanges)
            #expect(session.lastSavedAt == clock)
            let notes = try context.fetch(FetchDescriptor<PaperNote>())
            #expect(notes.count == 1)
        }

        // Reopen the SQLite store in a fresh ModelContainer and verify the saved drawing.
        let reloadedContainer = try ModelContainer(
            for: KurnModelGraph.schema,
            migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)]
        )
        let reloadedContext = reloadedContainer.mainContext
        let notes = try reloadedContext.fetch(FetchDescriptor<PaperNote>())
        let saved = try #require(notes.first)
        #expect(notes.count == 1)
        #expect(saved.recordingID == recordingID)
        #expect(saved.pageWidth == PaperNote.defaultPageWidth)
        #expect(saved.updatedAt == clock)
        try #require(saved.anchors.count == 2)
        #expect(saved.anchors[0].recordingOffset == 42.5)
        #expect(saved.anchors[0].strokeCount == 1)
        #expect(saved.anchors[1].recordingOffset == 92.5)
        #expect(saved.anchors[1].strokeCount == 2)

        let reloadedDrawing = saved.loadDrawing()
        #expect(reloadedDrawing.strokes.count == 2)
        #expect(saved.hasStrokes)
        #expect(abs(reloadedDrawing.bounds.minX - expectedDrawing.bounds.minX) < 1)
    }

    @Test func emptySessionDoesNotInsertEmptyPaperNote() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Quiet Meeting")
        context.insert(meeting)
        try context.save()

        let session = PaperNoteSession(meeting: meeting, modelContext: context, elapsed: { 10 })
        session.begin(recordingID: UUID())
        session.drawingDidChange(PKDrawing())
        session.finish()

        #expect(try context.fetch(FetchDescriptor<PaperNote>()).isEmpty)
    }

    @Test func strokesDrawnBeforeBeginArePersistedOnceRecordingStarts() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Early Sketch")
        context.insert(meeting)
        try context.save()

        let recordingID = UUID()
        let session = PaperNoteSession(meeting: meeting, modelContext: context, elapsed: { 0 })
        session.drawingDidChange(makeSampleDrawing())
        #expect(try context.fetch(FetchDescriptor<PaperNote>()).isEmpty)

        session.begin(recordingID: recordingID)
        session.flushNow()

        let saved = try #require(try context.fetch(FetchDescriptor<PaperNote>()).first)
        #expect(saved.recordingID == recordingID)
        #expect(saved.loadDrawing().strokes.count == 1)
    }

    // MARK: - Deletion

    @Test func deleteRecordingRowsRemovesMatchingPaperNoteAndLeavesOthers() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Multi Segment")
        context.insert(meeting)
        let first = Recording(meeting: meeting, fileName: "first.m4a", duration: 30)
        let second = Recording(meeting: meeting, fileName: "second.m4a", duration: 40)
        context.insert(first)
        context.insert(second)

        let firstNote = PaperNote(meeting: meeting, recordingID: first.id, drawingData: makeSampleDrawing().dataRepresentation())
        let secondNote = PaperNote(meeting: meeting, recordingID: second.id, drawingData: makeSampleDrawing(offsetY: 300).dataRepresentation())
        context.insert(firstNote)
        context.insert(secondNote)
        try context.save()

        MeetingLibrary.deleteRecordingRows(first, in: context)
        try context.save()

        let remainingNotes = try context.fetch(FetchDescriptor<PaperNote>())
        #expect(remainingNotes.map(\.recordingID) == [second.id])
    }

    @Test func deletingMeetingCascadesPaperNotesAndLibraryEraserRemovesOrphans() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Cascade")
        context.insert(meeting)
        context.insert(PaperNote(meeting: meeting, recordingID: UUID(), drawingData: makeSampleDrawing().dataRepresentation()))
        let orphan = PaperNote(meeting: nil, recordingID: UUID(), drawingData: makeSampleDrawing().dataRepresentation())
        context.insert(orphan)
        try context.save()

        try MeetingLibrary(context: context).deleteMeeting(meeting)
        #expect(try context.fetch(FetchDescriptor<PaperNote>()).map(\.id) == [orphan.id])

        try LibraryEraser.eraseModels(in: context)
        #expect(try context.fetch(FetchDescriptor<PaperNote>()).isEmpty)
    }

    @Test func cancelStopsPendingDebouncedWrite() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Cancelled")
        context.insert(meeting)
        try context.save()

        let sleepClock = VirtualSleepClock()
        let session = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(30),
            sleepClock: sleepClock,
            elapsed: { 5 }
        )
        session.begin(recordingID: UUID())
        session.drawingDidChange(makeSampleDrawing())
        await sleepClock.waitForWaiters(atLeast: 2)
        session.cancel()

        sleepClock.advance(by: 6.0)
        await session.waitForInFlightFlush()
        #expect(try context.fetch(FetchDescriptor<PaperNote>()).isEmpty)
    }

    // MARK: - V5 -> V6 Schema Migration

    @Test func aV5StoreMigratesToV6WithoutDataLossAndSupportsPaperNotes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaV5MigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("v5.store")

        let recordingID = UUID()
        let created = Date(timeIntervalSince1970: 1_760_000_000)

        do {
            let v5Schema = Schema(versionedSchema: KurnSchemaV5.self)
            let container = try ModelContainer(for: v5Schema, configurations: [ModelConfiguration(schema: v5Schema, url: storeURL)])
            let context = container.mainContext

            let meeting = KurnSchemaV5.Meeting(
                title: "Before paper notes",
                createdAt: created,
                notes: "Written at 1.4.0.",
                languageRaw: MeetingLanguage.english.rawValue
            )
            context.insert(meeting)
            let recording = KurnSchemaV5.Recording(
                id: recordingID,
                meeting: meeting,
                fileName: "v5.m4a",
                duration: 120,
                recordedAt: created,
                transcriptionStatusRaw: TranscriptionStatus.done.rawValue,
                transcriptionModeRaw: TranscriptionMode.onDevice.rawValue
            )
            context.insert(recording)
            let coachRecord = KurnSchemaV5.CoachRecord(
                meeting: meeting,
                recordingID: recordingID,
                userName: "Tester",
                createdAt: created
            )
            coachRecord.costUSD = 0.42
            context.insert(coachRecord)
            try context.save()
        }

        let migratedContainer = try ModelContainer(
            for: KurnModelGraph.schema,
            migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)]
        )
        let context = migratedContainer.mainContext

        let meeting = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
        #expect(meeting.title == "Before paper notes")
        #expect(meeting.recordings.map(\.id) == [recordingID])
        #expect(meeting.coachRecords.count == 1)
        #expect(meeting.coachRecords.first?.costUSD == 0.42)
        #expect(meeting.paperNotes.isEmpty)

        // V6 entity works cleanly on the migrated store.
        let note = PaperNote(
            meeting: meeting,
            recordingID: recordingID,
            drawingData: makeSampleDrawing().dataRepresentation(),
            anchors: [PaperStrokeAnchor(strokeCount: 1, recordingOffset: 12, recordedAt: created)]
        )
        context.insert(note)
        try context.save()
        #expect(meeting.sortedPaperNotes.count == 1)
        #expect(meeting.sortedPaperNotes.first?.loadDrawing().strokes.count == 1)
    }

    // MARK: - Layout & Page Coordinates

    @Test func paperCanvasMetricsKeepsPaperDominantInPortraitAndLandscapeOnIPadMini() {
        let portrait = CGSize(width: 744, height: 1_133)
        let landscape = CGSize(width: 1_133, height: 744)

        #expect(!PaperCanvasMetrics.isLandscape(portrait))
        #expect(PaperCanvasMetrics.isLandscape(landscape))

        // Portrait: full-width paper fits 1:1 with default page width.
        let portraitScale = PaperCanvasMetrics.displayScale(forViewportWidth: portrait.width)
        #expect(abs(portraitScale - 1.0) < 0.001)

        // Landscape: coach column beside paper leaves ~70% width for paper.
        let coachWidth = PaperCanvasMetrics.coachColumnWidth(forContainerSize: landscape)
        let landscapePaperWidth = landscape.width - coachWidth - 16
        let landscapeFraction = PaperCanvasMetrics.areaFraction(
            of: CGRect(x: 0, y: 0, width: landscapePaperWidth, height: landscape.height),
            in: landscape
        )
        #expect(coachWidth >= 280 && coachWidth <= 340)
        #expect(landscapeFraction > 0.65)

        // Rotating only changes display scale; stored drawing coordinates are untouched.
        let landscapeScale = PaperCanvasMetrics.displayScale(forViewportWidth: landscapePaperWidth)
        #expect(landscapeScale > 0.9)
        let grownHeight = PaperCanvasMetrics.pageHeight(viewportHeight: landscape.height, displayScale: landscapeScale, drawingMaxY: 1_400)
        #expect(grownHeight >= 1_400 + PaperCanvasMetrics.bottomGrowthMargin)
    }

    // MARK: - Read-only Viewer & Bounded Preview

    private func findSubview<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let found = findSubview(of: type, in: child) { return found }
        }
        return nil
    }

    @Test func tallDrawingViewerUsesReadOnlyCanvasWithoutFullHeightBitmap() async throws {
        let topStroke = makeSampleDrawing(offsetY: 120)
        let bottomStroke = makeSampleDrawing(offsetY: 20_000)
        let tallDrawing = PKDrawing(strokes: topStroke.strokes + bottomStroke.strokes)
        #expect(tallDrawing.bounds.maxY >= 20_000)

        let note = PaperNote(
            recordingID: UUID(),
            drawingData: tallDrawing.dataRepresentation(),
            pageWidth: PaperNote.defaultPageWidth
        )

        let hosting = UIHostingController(rootView: PaperNoteViewerView(note: note))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 744, height: 1_000))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.view.layoutIfNeeded()

        let canvas = try #require(
            findSubview(of: PKCanvasView.self, in: hosting.view),
            "PaperNoteViewerView must render via a read-only PKCanvasView instead of allocating a full-height bitmap"
        )
        #expect(!canvas.drawingGestureRecognizer.isEnabled)
        #expect(canvas.isUserInteractionEnabled)
        #expect(canvas.isScrollEnabled)
        #expect(canvas.drawing.strokes.count == 2)
        #expect(canvas.contentSize.height >= 20_000 * max(0.25, canvas.zoomScale))

        window.isHidden = true
    }

    @Test func previewThumbnailBoundsBitmapSizeAndDecodesOncePerRevision() {
        let topStroke = makeSampleDrawing(offsetY: 120)
        let bottomStroke = makeSampleDrawing(offsetY: 20_000)
        let tallDrawing = PKDrawing(strokes: topStroke.strokes + bottomStroke.strokes)
        let note = PaperNote(
            recordingID: UUID(),
            drawingData: tallDrawing.dataRepresentation(),
            pageWidth: PaperNote.defaultPageWidth
        )

        var decodeCount = 0
        var recordedRects: [CGRect] = []
        var recordedScales: [CGFloat] = []
        let cache = PaperNoteThumbnailCache()

        for _ in 0..<5 {
            let image = cache.image(
                for: note,
                displayScale: 2,
                decode: { item in
                    decodeCount += 1
                    return item.loadDrawing()
                },
                render: { drawing, rect, scale in
                    recordedRects.append(rect)
                    recordedScales.append(scale)
                    return PaperNoteThumbnail.defaultRender(drawing: drawing, rect: rect, scale: scale)
                }
            )
            #expect(image != nil)
        }

        #expect(decodeCount == 1)
        #expect(recordedRects.count == 1)
        let rect = recordedRects[0]
        let scale = recordedScales[0]
        #expect(rect.height <= CGFloat(note.pageWidth) * 1.5)
        #expect(rect.width * scale <= PaperNoteThumbnail.maxPixelDimension + 1)
        #expect(rect.height * scale <= PaperNoteThumbnail.maxPixelDimension + 1)

        // Drawing cache also decodes once across repeated reads until updatedAt changes.
        let drawingCache = PaperNoteDrawingCache()
        var viewerDecodeCount = 0
        for _ in 0..<4 {
            let decoded = drawingCache.drawing(for: note) { item in
                viewerDecodeCount += 1
                return item.loadDrawing()
            }
            #expect(decoded.strokes.count == 2)
        }
        #expect(viewerDecodeCount == 1)

        note.updatedAt = note.updatedAt.addingTimeInterval(5)
        _ = drawingCache.drawing(for: note) { item in
            viewerDecodeCount += 1
            return item.loadDrawing()
        }
        #expect(viewerDecodeCount == 2)
    }

    // MARK: - Inline Storage & Off-Main Serialization

    private func makeLargeDrawing(strokeCount: Int = 400) -> PKDrawing {
        var strokes: [PKStroke] = []
        strokes.reserveCapacity(strokeCount)
        let creationDate = Date(timeIntervalSince1970: 1_760_000_000)
        for index in 0..<strokeCount {
            let baseY = CGFloat(40 + index * 12)
            let points: [PKStrokePoint] = (0..<24).map { step in
                let x = CGFloat(40 + step * 24)
                let y = baseY + CGFloat(sin(Double(step)) * 4.0)
                return PKStrokePoint(
                    location: CGPoint(x: x, y: y),
                    timeOffset: TimeInterval(step) * 0.02,
                    size: CGSize(width: 4, height: 4),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            }
            let path = PKStrokePath(controlPoints: points, creationDate: creationDate)
            strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: path))
        }
        return PKDrawing(strokes: strokes)
    }

    @Test func paperNoteDrawingDataStaysInlineAndSurvivesBackupRestore() throws {
        let schema = Schema([PaperNote.self])
        let entity = try #require(schema.entities.first { $0.name == "PaperNote" })
        let drawingAttribute = try #require(entity.attributes.first { $0.name == "drawingData" })
        #expect(!drawingAttribute.options.contains(.externalStorage))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperNoteBackupRestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent(ModelStoreProtection.baseName)

        let largeDrawing = makeLargeDrawing()
        let largeData = largeDrawing.dataRepresentation()
        try #require(largeData.count > 130_000, "Drawing payload must exceed CoreData external-storage threshold")
        let recordingID = UUID()

        do {
            let container = try ModelContainer(
                for: KurnModelGraph.schema,
                migrationPlan: KurnModelGraph.migrationPlan,
                configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)]
            )
            let context = container.mainContext
            let meeting = Meeting(title: "Backup Roundtrip")
            context.insert(meeting)
            let note = PaperNote(meeting: meeting, recordingID: recordingID, drawingData: largeData)
            context.insert(note)
            try context.save()
        }

        let manager = ModelStoreBackupManager(appSupportDirectory: directory)
        let generation = try #require(try manager.createBackupIfLiveStoreExists())

        // Delete the note in the live store (removing any external blob sidecars) before restoring.
        do {
            let container = try ModelContainer(
                for: KurnModelGraph.schema,
                migrationPlan: KurnModelGraph.migrationPlan,
                configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)]
            )
            let context = container.mainContext
            for note in try context.fetch(FetchDescriptor<PaperNote>()) {
                context.delete(note)
            }
            try context.save()
        }

        try manager.restore(generation: generation)

        let restoredContainer = try ModelContainer(
            for: KurnModelGraph.schema,
            migrationPlan: KurnModelGraph.migrationPlan,
            configurations: [ModelConfiguration(schema: KurnModelGraph.schema, url: storeURL)]
        )
        let restoredNotes = try restoredContainer.mainContext.fetch(FetchDescriptor<PaperNote>())
        let restored = try #require(restoredNotes.first)
        #expect(restored.recordingID == recordingID)
        #expect(restored.loadDrawing().strokes.count == largeDrawing.strokes.count)
    }

    private nonisolated static func isCurrentThreadMain() -> Bool {
        Thread.isMainThread
    }

    private final class GatedDrawingSerializer: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var maxActive = 0
        private var calls = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var observedMainThread: [Bool] = []

        var maxConcurrent: Int { lock.withLock { maxActive } }
        var callCount: Int { lock.withLock { calls } }
        var ranOffMainThread: Bool { lock.withLock { !observedMainThread.isEmpty && observedMainThread.allSatisfy { !$0 } } }

        func serialize(_ snapshot: PaperDrawingSnapshot) async -> Data {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    calls += 1
                    active += 1
                    maxActive = max(maxActive, active)
                    waiters.append(continuation)
                }
            }
            let data = await PaperNoteSession.serializeOffMain(snapshot) { snap in
                let onMain = PaperNoteTests.isCurrentThreadMain()
                self.lock.withLock { self.observedMainThread.append(onMain) }
                return snap.drawing.dataRepresentation()
            }
            lock.withLock {
                active -= 1
            }
            return data
        }

        func releaseNext() {
            let next: CheckedContinuation<Void, Never>? = lock.withLock {
                guard !waiters.isEmpty else { return nil }
                return waiters.removeFirst()
            }
            next?.resume()
        }

        var hasWaitingCall: Bool {
            lock.withLock { !waiters.isEmpty }
        }
    }

    @Test func defaultSerializerRunsOffMainActorAndCoalescesInFlightWrites() async throws {
        // Verify production default serializer (`serializeOffMain`) runs off the main thread.
        let sample = makeSampleDrawing()
        let offMainLock = NSLock()
        nonisolated(unsafe) var serializedOnMain: Bool?
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Off-Main")
        context.insert(meeting)
        try context.save()

        let offMainSession = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(20),
            elapsed: { 12 },
            serialize: { snapshot in
                await PaperNoteSession.serializeOffMain(snapshot) { snap in
                    let onMain = PaperNoteTests.isCurrentThreadMain()
                    offMainLock.withLock { serializedOnMain = onMain }
                    return snap.drawing.dataRepresentation()
                }
            }
        )
        offMainSession.begin(recordingID: UUID())
        offMainSession.drawingDidChange(sample)
        await offMainSession.flush()
        #expect(offMainLock.withLock { serializedOnMain } == false)
        #expect(!offMainSession.hasUnsavedChanges)

        // Verify rapid edits while one serialization is in flight coalesce into at most one in-flight task.
        let gate = GatedDrawingSerializer()
        let coalescedSession = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(10),
            elapsed: { 25 },
            serialize: { snapshot in await gate.serialize(snapshot) }
        )
        let recordingID = UUID()
        coalescedSession.begin(recordingID: recordingID)

        let stroke1 = makeSampleDrawing(offsetY: 120)
        let stroke2 = PKDrawing(strokes: stroke1.strokes + makeSampleDrawing(offsetY: 220).strokes)
        let stroke3 = PKDrawing(strokes: stroke2.strokes + makeSampleDrawing(offsetY: 320).strokes)

        coalescedSession.drawingDidChange(stroke1)
        coalescedSession.requestFlush()
        for _ in 0..<50 where !gate.hasWaitingCall {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.callCount == 1)
        #expect(gate.maxConcurrent == 1)

        // Multiple edits + flush triggers while #1 is in flight must never spawn a 2nd concurrent serialization.
        coalescedSession.drawingDidChange(stroke2)
        coalescedSession.requestFlush()
        coalescedSession.drawingDidChange(stroke3)
        coalescedSession.requestFlush()
        try await Task.sleep(for: .milliseconds(30))
        #expect(gate.callCount == 1)
        #expect(gate.maxConcurrent == 1)

        // Releasing #1 triggers one coalesced follow-up serialization for stroke3.
        gate.releaseNext()
        for _ in 0..<50 where !gate.hasWaitingCall {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.callCount == 2)
        #expect(gate.maxConcurrent == 1)

        gate.releaseNext()
        for _ in 0..<50 where coalescedSession.hasUnsavedChanges {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(!coalescedSession.hasUnsavedChanges)
        #expect(gate.callCount == 2)
        #expect(gate.maxConcurrent == 1)
        #expect(gate.ranOffMainThread)

        let notes = try context.fetch(FetchDescriptor<PaperNote>(predicate: #Predicate { $0.recordingID == recordingID }))
        #expect(notes.count == 1)
        #expect(notes.first?.loadDrawing().strokes.count == 3)
    }

    @Test func failedSaveKeepsPendingStateAndRetriesWithoutDuplicateAnchors() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Retry")
        context.insert(meeting)
        try context.save()

        var shouldFail = true
        let clock = Date(timeIntervalSince1970: 1_760_000_100)
        let session = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(20),
            elapsed: { 33 },
            now: { clock },
            persist: { ctx in
                if shouldFail {
                    return .persistenceFailed("simulated disk error")
                }
                return ctx.saveOrError()
            }
        )
        let recordingID = UUID()
        session.begin(recordingID: recordingID)
        session.drawingDidChange(makeSampleDrawing())
        await session.flush()

        #expect(session.hasUnsavedChanges)
        #expect(session.lastSavedAt == nil)
        #expect(session.anchors.isEmpty)

        shouldFail = false
        await session.flush()

        #expect(!session.hasUnsavedChanges)
        #expect(session.lastSavedAt == clock)
        #expect(session.anchors.count == 1)
        #expect(session.anchors.first?.recordingOffset == 33)
        let saved = try #require(
            try context.fetch(FetchDescriptor<PaperNote>(predicate: #Predicate { $0.recordingID == recordingID })).first
        )
        #expect(saved.loadDrawing().strokes.count == 1)
    }

    @Test func inFlightBatchAndNewStrokeBatchPreserveDistinctAnchorsOnFinish() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Anchor Race")
        context.insert(meeting)
        try context.save()

        let gate = GatedDrawingSerializer()
        let sleepClock = VirtualSleepClock()
        var clock = Date(timeIntervalSince1970: 1_760_000_000)
        var elapsed: TimeInterval = 42.5
        let recordingID = UUID()

        let session = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(30),
            sleepClock: sleepClock,
            elapsed: { elapsed },
            now: { clock },
            serialize: { snapshot in await gate.serialize(snapshot) }
        )
        session.begin(recordingID: recordingID)

        let stroke1 = makeSampleDrawing(offsetY: 160)
        session.drawingDidChange(stroke1)
        await sleepClock.waitForWaiters(atLeast: 2)
        sleepClock.advance(by: 0.03)
        for _ in 0..<100 where !gate.hasWaitingCall {
            await Task.yield()
        }
        try #require(gate.hasWaitingCall)

        // Second stroke batch arrives while batch 1's serialization is in flight.
        clock = Date(timeIntervalSince1970: 1_760_000_050)
        elapsed = 92.5
        let stroke2 = PKDrawing(strokes: stroke1.strokes + makeSampleDrawing(offsetY: 260).strokes)
        session.drawingDidChange(stroke2)
        session.finish()
        gate.releaseNext()

        let saved = try #require(
            try context.fetch(FetchDescriptor<PaperNote>(predicate: #Predicate { $0.recordingID == recordingID })).first
        )
        try #require(saved.anchors.count == 2)
        #expect(saved.anchors[0].recordingOffset == 42.5)
        #expect(saved.anchors[0].strokeCount == 1)
        #expect(saved.anchors[1].recordingOffset == 92.5)
        #expect(saved.anchors[1].strokeCount == 2)
    }
}
