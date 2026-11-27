//
//  PaperNote.swift
//  Kurn
//
//  Handwritten notes authored on the paper recording screen for one recording.
//  Stored as PencilKit `PKDrawing` bytes in fixed page coordinates so rotating
//  the iPad only changes the display transform, never the persisted strokes.
//  Optional stroke-batch time anchors record the elapsed recording offset when
//  each batch finished, for later export.
//

import Foundation
import KurnCore
import PencilKit
import SwiftData

/// Recording-relative timestamp recorded when a stroke batch finishes, so
/// future exports can correlate handwritten notes with the audio timeline.
struct PaperStrokeAnchor: Codable, Equatable, Sendable {
    let strokeCount: Int
    let recordingOffset: TimeInterval
    let recordedAt: Date
}

@Model
final class PaperNote {
    /// Default logical page width in points (iPad mini portrait width).
    static let defaultPageWidth: Double = 744

    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var recordingID: UUID?
    /// `PKDrawing.dataRepresentation()` in page coordinates.
    @Attribute(.externalStorage) var drawingData: Data = Data()
    /// Logical page width in points that `drawingData` was authored against.
    var pageWidth: Double = PaperNote.defaultPageWidth
    /// JSON-encoded `[PaperStrokeAnchor]` carrying recording time offsets.
    var anchorsData: Data = Data()
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        recordingID: UUID? = nil,
        drawingData: Data = Data(),
        pageWidth: Double = PaperNote.defaultPageWidth,
        anchors: [PaperStrokeAnchor] = [],
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.meeting = meeting
        self.recordingID = recordingID
        self.drawingData = drawingData
        self.pageWidth = pageWidth
        self.anchorsData = JSONStorage.encode(anchors)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var anchors: [PaperStrokeAnchor] {
        get { JSONStorage.decode([PaperStrokeAnchor].self, from: anchorsData) }
        set { anchorsData = JSONStorage.encode(newValue) }
    }

    /// Decodes the persisted `PKDrawing`, returning an empty drawing when no
    /// bytes are stored or when the payload cannot be decoded.
    func loadDrawing() -> PKDrawing {
        guard !drawingData.isEmpty else { return PKDrawing() }
        return (try? PKDrawing(data: drawingData)) ?? PKDrawing()
    }

    /// True when the stored drawing contains at least one visible stroke.
    var hasStrokes: Bool {
        !loadDrawing().strokes.isEmpty
    }
}
