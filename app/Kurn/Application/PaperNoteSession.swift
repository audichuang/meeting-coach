//
//  PaperNoteSession.swift
//  Kurn
//
//  Owns handwritten-note persistence for one live recording session.
//  Completely off the audio path: writing strokes only schedules a debounced
//  SwiftData save on the main actor and reads the recorder's current elapsed
//  time as an optional export anchor. Failures are logged and never interrupt
//  recording.
//

import Foundation
import KurnCore
import Observation
import PencilKit
import SwiftData

@MainActor
@Observable
final class PaperNoteSession {
    /// Current drawing in logical page coordinates.
    private(set) var drawing: PKDrawing
    /// Logical page width in points that strokes are authored against.
    let pageWidth: Double
    /// Timestamp of the last successful SwiftData save, if any.
    private(set) var lastSavedAt: Date?
    /// True while edits have not yet been committed to SwiftData.
    private(set) var hasUnsavedChanges = false
    /// Recording-relative time anchors for stroke batches.
    private(set) var anchors: [PaperStrokeAnchor] = []
    /// Active recording id once capture owns a `Recording` row.
    private(set) var recordingID: UUID?

    @ObservationIgnored private let meeting: Meeting
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let elapsed: @MainActor () -> TimeInterval
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let debounceInterval: Duration
    @ObservationIgnored private let persist: @MainActor (ModelContext) -> AppError?
    @ObservationIgnored private var note: PaperNote?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingBatchOffset: TimeInterval?
    @ObservationIgnored private var isCancelled = false

    init(
        meeting: Meeting,
        modelContext: ModelContext,
        pageWidth: Double = PaperNote.defaultPageWidth,
        debounceInterval: Duration = .milliseconds(500),
        elapsed: @escaping @MainActor () -> TimeInterval,
        now: @escaping @MainActor () -> Date = { Date() },
        persist: @escaping @MainActor (ModelContext) -> AppError? = { $0.saveOrError() }
    ) {
        self.meeting = meeting
        self.modelContext = modelContext
        self.pageWidth = pageWidth
        self.debounceInterval = debounceInterval
        self.elapsed = elapsed
        self.now = now
        self.persist = persist
        self.drawing = PKDrawing()
    }

    /// Attaches this session to the newly created recording row. If the user
    /// already started sketching while the microphone was preparing, schedules
    /// persistence immediately.
    func begin(recordingID: UUID) {
        guard !isCancelled else { return }
        self.recordingID = recordingID
        if hasUnsavedChanges {
            scheduleDebouncedSave()
        }
    }

    /// Called by the PencilKit canvas delegate after strokes change.
    /// Stores the latest drawing in page coordinates and schedules a debounced
    /// save without doing synchronous disk work on every stroke.
    func drawingDidChange(_ newDrawing: PKDrawing) {
        guard !isCancelled else { return }
        drawing = newDrawing
        hasUnsavedChanges = true
        if pendingBatchOffset == nil {
            pendingBatchOffset = max(0, elapsed())
        }
        scheduleDebouncedSave()
    }

    /// Immediately commits any pending drawing changes to SwiftData.
    /// Safe to call repeatedly; a no-op when nothing changed or no recording
    /// owns this session yet.
    func flushNow() {
        debounceTask?.cancel()
        debounceTask = nil
        guard !isCancelled, hasUnsavedChanges, let recordingID else { return }

        let strokeCount = drawing.strokes.count
        if note == nil, strokeCount == 0 {
            hasUnsavedChanges = false
            pendingBatchOffset = nil
            return
        }

        let timestamp = now()
        if let batchOffset = pendingBatchOffset, strokeCount > 0 {
            anchors.append(PaperStrokeAnchor(
                strokeCount: strokeCount,
                recordingOffset: batchOffset,
                recordedAt: timestamp
            ))
            pendingBatchOffset = nil
        }

        let target: PaperNote
        if let existing = note {
            target = existing
        } else {
            let created = PaperNote(
                meeting: meeting,
                recordingID: recordingID,
                pageWidth: pageWidth,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            modelContext.insert(created)
            note = created
            target = created
        }

        target.drawingData = drawing.dataRepresentation()
        target.anchors = anchors
        target.updatedAt = timestamp

        if let failure = persist(modelContext) {
            AppLog.persistence.atError.error("PaperNoteSession: save failed code=\(failure.logCode, privacy: .public)")
            return
        }
        lastSavedAt = timestamp
        hasUnsavedChanges = false
    }

    /// Flushes any pending strokes before recording finalization completes.
    func finish() {
        flushNow()
    }

    /// Cancels any pending debounced write and detaches from SwiftData.
    /// Callers deleting the `Recording` remove any persisted `PaperNote` row
    /// through `MeetingLibrary.deleteRecordingRows`.
    func cancel() {
        isCancelled = true
        debounceTask?.cancel()
        debounceTask = nil
        note = nil
        recordingID = nil
        hasUnsavedChanges = false
        pendingBatchOffset = nil
    }

    private func scheduleDebouncedSave() {
        debounceTask?.cancel()
        guard recordingID != nil else { return }
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushNow()
        }
    }
}
