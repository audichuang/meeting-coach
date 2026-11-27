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

            let session = PaperNoteSession(
                meeting: meeting,
                modelContext: context,
                debounceInterval: .milliseconds(30),
                elapsed: { elapsed },
                now: { clock }
            )
            session.begin(recordingID: recordingID)
            session.drawingDidChange(expectedDrawing)
            #expect(session.hasUnsavedChanges)

            try await Task.sleep(for: .milliseconds(120))
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
        #expect(saved.anchors.count == 2)
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

        let session = PaperNoteSession(
            meeting: meeting,
            modelContext: context,
            debounceInterval: .milliseconds(30),
            elapsed: { 5 }
        )
        session.begin(recordingID: UUID())
        session.drawingDidChange(makeSampleDrawing())
        session.cancel()

        try await Task.sleep(for: .milliseconds(90))
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
}
