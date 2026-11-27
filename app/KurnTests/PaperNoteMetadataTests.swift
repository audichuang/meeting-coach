//
//  PaperNoteMetadataTests.swift
//  KurnTests
//
//  Verifies `PaperNote.strokeCount` / `hasStrokes` persisted metadata so list
//  views filter non-empty notes without decoding `PKDrawing` blobs in `body`.
//

import CoreGraphics
import Foundation
import PencilKit
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct PaperNoteMetadataTests {

    private func makeStroke(offsetY: CGFloat) -> PKStroke {
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
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    @Test func hasStrokesUsesPersistedMetadataWithoutDecodingDrawingData() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Metadata Filter")
        context.insert(meeting)
        try context.save()

        let recordingID = UUID()
        let session = PaperNoteSession(meeting: meeting, modelContext: context, elapsed: { 10 })
        session.begin(recordingID: recordingID)

        let twoStrokes = PKDrawing(strokes: [makeStroke(offsetY: 120), makeStroke(offsetY: 220)])
        session.drawingDidChange(twoStrokes)
        #expect(await session.finish())

        let saved = try #require(
            try context.fetch(FetchDescriptor<PaperNote>(predicate: #Predicate { $0.recordingID == recordingID })).first
        )
        #expect(saved.strokeCount == 2)
        #expect(saved.hasStrokes)

        // Replace raw bytes with non-PKDrawing sentinel data in memory: `hasStrokes`
        // must read persisted metadata instead of decoding `drawingData`.
        let originalBytes = saved.drawingData
        saved.drawingData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(saved.hasStrokes, "hasStrokes must not decode drawingData")
        saved.drawingData = originalBytes

        // Erasing all strokes updates the persisted metadata back to empty.
        session.drawingDidChange(PKDrawing())
        #expect(await session.finish())
        #expect(saved.strokeCount == 0)
        #expect(!saved.hasStrokes)
    }
}
