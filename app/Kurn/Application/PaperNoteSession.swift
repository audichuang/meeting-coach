//
//  PaperNoteSession.swift
//  Kurn
//
//  Owns handwritten-note persistence for one live recording session.
//  Completely off the audio path: writing strokes schedules a debounced
//  background serialization of a `PKDrawing` value snapshot (at most one
//  serialization in flight, coalescing rapid edits) and applies the bytes to
//  SwiftData on the main actor. Failures are logged and never interrupt
//  recording.
//

import Foundation
import KurnCore
import Observation
import PencilKit
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Value snapshot of a `PKDrawing` sent off the main actor for encoding.
/// `PKDrawing` is a copy-on-write value type whose `dataRepresentation()`
/// only reads its immutable stroke data.
struct PaperDrawingSnapshot: @unchecked Sendable {
    let drawing: PKDrawing
    let strokeCount: Int

    init(_ drawing: PKDrawing) {
        self.drawing = drawing
        self.strokeCount = drawing.strokes.count
    }
}

@MainActor
@Observable
final class PaperNoteSession {
    typealias DrawingSerializer = @Sendable (PaperDrawingSnapshot) async -> Data

    /// Current drawing in logical page coordinates.
    private(set) var drawing: PKDrawing
    /// Logical page width in points that strokes are authored against.
    let pageWidth: Double
    /// Timestamp of the last successful SwiftData save, if any.
    private(set) var lastSavedAt: Date?
    /// Last persistence error observed while saving, cleared on the next save.
    private(set) var lastSaveError: AppError?
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
    @ObservationIgnored private let maxWaitInterval: Duration
    @ObservationIgnored private let retryBaseInterval: Duration
    @ObservationIgnored private let maxAutomaticRetries: Int
    @ObservationIgnored private let sleepClock: any SleepClock
    @ObservationIgnored private let persist: @MainActor (ModelContext) -> AppError?
    @ObservationIgnored private let serialize: DrawingSerializer
    @ObservationIgnored private var note: PaperNote?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var maxWaitTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var serializationTask: Task<Void, Never>?
    @ObservationIgnored private var drawingGeneration: UInt64 = 0
    @ObservationIgnored private var persistedGeneration: UInt64 = 0
    @ObservationIgnored private var inFlightGeneration: UInt64 = 0
    @ObservationIgnored private var consecutiveSaveFailures = 0
    @ObservationIgnored private var needsFollowUpFlush = false
    @ObservationIgnored private var pendingBatchOffset: TimeInterval?
    @ObservationIgnored private var isCancelled = false

    nonisolated static func serializeOffMain(
        _ snapshot: PaperDrawingSnapshot,
        encode: @escaping @Sendable (PaperDrawingSnapshot) -> Data = { $0.drawing.dataRepresentation() }
    ) async -> Data {
        await Task.detached(priority: .utility) {
            encode(snapshot)
        }.value
    }

    init(
        meeting: Meeting,
        modelContext: ModelContext,
        pageWidth: Double = PaperNote.defaultPageWidth,
        debounceInterval: Duration = .milliseconds(500),
        maxWaitInterval: Duration = .seconds(5),
        retryBaseInterval: Duration = .seconds(1),
        maxAutomaticRetries: Int = 3,
        sleepClock: any SleepClock = SystemClock(),
        elapsed: @escaping @MainActor () -> TimeInterval,
        now: @escaping @MainActor () -> Date = { Date() },
        persist: @escaping @MainActor (ModelContext) -> AppError? = { $0.saveOrError() },
        serialize: @escaping DrawingSerializer = { await PaperNoteSession.serializeOffMain($0) }
    ) {
        self.meeting = meeting
        self.modelContext = modelContext
        self.pageWidth = pageWidth
        self.debounceInterval = debounceInterval
        self.maxWaitInterval = maxWaitInterval
        self.retryBaseInterval = retryBaseInterval
        self.maxAutomaticRetries = max(0, maxAutomaticRetries)
        self.sleepClock = sleepClock
        self.elapsed = elapsed
        self.now = now
        self.persist = persist
        self.serialize = serialize
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
    /// background serialization without doing synchronous disk work on every stroke.
    func drawingDidChange(_ newDrawing: PKDrawing) {
        guard !isCancelled else { return }
        drawing = newDrawing
        drawingGeneration &+= 1
        hasUnsavedChanges = true
        consecutiveSaveFailures = 0
        retryTask?.cancel()
        retryTask = nil
        if pendingBatchOffset == nil {
            pendingBatchOffset = max(0, elapsed())
        }
        scheduleDebouncedSave()
    }

    /// Requests an immediate off-main-actor serialization and save, coalescing
    /// with any serialization already in flight so at most one runs at a time.
    func requestFlush() {
        consecutiveSaveFailures = 0
        startCoalescedBackgroundFlush()
    }

    /// Requests an off-main-actor flush and waits until the in-flight
    /// serialization (and any coalesced follow-up) completes.
    /// Returns `true` when all pending changes were persisted (or nothing was
    /// pending), and `false` when cancelled, unattached, or persistence failed.
    @discardableResult
    func flush() async -> Bool {
        guard !isCancelled else { return false }
        if !hasUnsavedChanges, serializationTask == nil {
            return true
        }
        guard recordingID != nil else { return false }
        consecutiveSaveFailures = 0
        startCoalescedBackgroundFlush()
        await waitForInFlightFlush()
        return !isCancelled && !hasUnsavedChanges && lastSaveError == nil
    }

    /// Waits for any serialization already in flight (and any coalesced
    /// follow-up) to finish without triggering a new flush.
    func waitForInFlightFlush() async {
        while let task = serializationTask {
            await task.value
        }
    }

    /// Flushes unsaved strokes when the app moves to the background, requesting
    /// brief background execution time so serialization and save complete
    /// before iOS suspends the process. Returns the background flush task
    /// reporting `true` on success and `false` on failure, or `nil` when
    /// nothing needed flushing.
    @discardableResult
    func flushForBackground() -> Task<Bool, Never>? {
        guard !isCancelled, hasUnsavedChanges, recordingID != nil else { return nil }
        #if canImport(UIKit)
        let application = UIApplication.shared
        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = application.beginBackgroundTask(withName: "PaperNoteBackgroundFlush") {
            if backgroundTaskID != .invalid {
                application.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        return Task { @MainActor [weak self] in
            let succeeded = await self?.flush() ?? false
            if backgroundTaskID != .invalid {
                application.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
            return succeeded
        }
        #else
        return Task { @MainActor [weak self] in
            await self?.flush() ?? false
        }
        #endif
    }

    /// Waits for any in-flight serialization to complete and then serializes
    /// and persists the latest unsaved strokes off the main actor.
    /// Never cancels an in-flight serialization, never runs two serializations
    /// concurrently, and never calls `PKDrawing.dataRepresentation()` on the
    /// main actor.
    @discardableResult
    func finish() async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        maxWaitTask?.cancel()
        maxWaitTask = nil
        retryTask?.cancel()
        retryTask = nil
        guard !isCancelled else { return false }
        return await flush()
    }

    /// Starts an off-main finish without blocking synchronous recording stop.
    /// Retains the session until `finish()` completes and guards the write with
    /// a background task on iOS.
    @discardableResult
    func finishInBackground() -> Task<Bool, Never>? {
        guard !isCancelled else { return nil }
        debounceTask?.cancel()
        debounceTask = nil
        maxWaitTask?.cancel()
        maxWaitTask = nil
        retryTask?.cancel()
        retryTask = nil
        guard hasUnsavedChanges || serializationTask != nil, recordingID != nil else { return nil }
        #if canImport(UIKit)
        let application = UIApplication.shared
        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = application.beginBackgroundTask(withName: "PaperNoteFinish") {
            if backgroundTaskID != .invalid {
                application.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        return Task { @MainActor in
            let succeeded = await self.finish()
            if backgroundTaskID != .invalid {
                application.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
            return succeeded
        }
        #else
        return Task { @MainActor in
            await self.finish()
        }
        #endif
    }

    /// Cancels any pending debounced or in-flight write and detaches from SwiftData.
    /// Callers deleting the `Recording` remove any persisted `PaperNote` row
    /// through `MeetingLibrary.deleteRecordingRows`.
    func cancel() {
        isCancelled = true
        debounceTask?.cancel()
        debounceTask = nil
        maxWaitTask?.cancel()
        maxWaitTask = nil
        retryTask?.cancel()
        retryTask = nil
        serializationTask?.cancel()
        serializationTask = nil
        inFlightGeneration = 0
        consecutiveSaveFailures = 0
        needsFollowUpFlush = false
        note = nil
        recordingID = nil
        hasUnsavedChanges = false
        lastSaveError = nil
        pendingBatchOffset = nil
    }

    private func scheduleDebouncedSave() {
        debounceTask?.cancel()
        guard recordingID != nil else { return }
        let debounceSeconds = Self.seconds(from: debounceInterval)
        let clock = sleepClock
        debounceTask = Task { [weak self] in
            do {
                try await clock.sleep(seconds: debounceSeconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.debounceTask = nil
            self.startCoalescedBackgroundFlush()
        }
        scheduleMaxWaitIfNeeded()
    }

    private func scheduleMaxWaitIfNeeded() {
        guard recordingID != nil, maxWaitTask == nil else { return }
        let maxWaitSeconds = Self.seconds(from: maxWaitInterval)
        let clock = sleepClock
        maxWaitTask = Task { [weak self] in
            do {
                try await clock.sleep(seconds: maxWaitSeconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.maxWaitTask = nil
            self.startCoalescedBackgroundFlush()
        }
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    private func scheduleBoundedRetryIfAllowed() {
        retryTask?.cancel()
        retryTask = nil
        maxWaitTask?.cancel()
        maxWaitTask = nil
        guard !isCancelled, hasUnsavedChanges, recordingID != nil else { return }
        guard consecutiveSaveFailures <= maxAutomaticRetries else {
            AppLog.persistence.atError.error(
                "PaperNoteSession: retry budget exhausted after \(self.consecutiveSaveFailures, privacy: .public) failures"
            )
            return
        }
        let baseSeconds = Self.seconds(from: retryBaseInterval)
        let maxWaitSeconds = Self.seconds(from: maxWaitInterval)
        let shift = min(max(0, consecutiveSaveFailures - 1), 6)
        let delay = min(maxWaitSeconds, baseSeconds * Double(1 << shift))
        let clock = sleepClock
        retryTask = Task { [weak self] in
            do {
                try await clock.sleep(seconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.retryTask = nil
            self.startCoalescedBackgroundFlush()
        }
    }

    private func startCoalescedBackgroundFlush() {
        debounceTask?.cancel()
        debounceTask = nil
        retryTask?.cancel()
        retryTask = nil
        guard !isCancelled, hasUnsavedChanges, recordingID != nil else { return }

        if serializationTask != nil {
            needsFollowUpFlush = true
            return
        }

        let snapshot = PaperDrawingSnapshot(drawing)
        if note == nil, snapshot.strokeCount == 0 {
            hasUnsavedChanges = false
            pendingBatchOffset = nil
            persistedGeneration = drawingGeneration
            return
        }

        let generation = drawingGeneration
        let batchOffset = pendingBatchOffset
        pendingBatchOffset = nil
        inFlightGeneration = generation
        let serialize = self.serialize

        serializationTask = Task { [weak self] in
            let data = await serialize(snapshot)
            guard !Task.isCancelled else { return }
            self?.completeBackgroundFlush(
                data: data,
                strokeCount: snapshot.strokeCount,
                generation: generation,
                batchOffset: batchOffset
            )
        }
    }

    private func completeBackgroundFlush(
        data: Data,
        strokeCount: Int,
        generation: UInt64,
        batchOffset: TimeInterval?
    ) {
        if generation == inFlightGeneration {
            serializationTask = nil
            inFlightGeneration = 0
        }

        guard !isCancelled, let recordingID else { return }
        guard generation > persistedGeneration else {
            if hasUnsavedChanges, needsFollowUpFlush {
                needsFollowUpFlush = false
                startCoalescedBackgroundFlush()
            }
            return
        }

        let saved = applySerializedDrawing(
            data: data,
            strokeCount: strokeCount,
            recordingID: recordingID,
            generation: generation,
            batchOffset: batchOffset
        )
        guard saved else {
            needsFollowUpFlush = false
            hasUnsavedChanges = true
            consecutiveSaveFailures += 1
            scheduleBoundedRetryIfAllowed()
            return
        }

        if drawingGeneration == persistedGeneration {
            hasUnsavedChanges = false
            needsFollowUpFlush = false
            maxWaitTask?.cancel()
            maxWaitTask = nil
        } else {
            hasUnsavedChanges = true
            if needsFollowUpFlush {
                needsFollowUpFlush = false
                startCoalescedBackgroundFlush()
            } else if debounceTask == nil {
                scheduleDebouncedSave()
            } else {
                scheduleMaxWaitIfNeeded()
            }
        }
    }

    private func applySerializedDrawing(
        data: Data,
        strokeCount: Int,
        recordingID: UUID,
        generation: UInt64,
        batchOffset: TimeInterval?
    ) -> Bool {
        let timestamp = now()
        var appendedAnchor = false
        if let batchOffset, strokeCount > 0 {
            anchors.append(PaperStrokeAnchor(
                strokeCount: strokeCount,
                recordingOffset: batchOffset,
                recordedAt: timestamp
            ))
            appendedAnchor = true
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

        target.drawingData = data
        target.strokeCount = strokeCount
        target.anchors = anchors
        target.updatedAt = timestamp

        if let failure = persist(modelContext) {
            AppLog.persistence.atError.error("PaperNoteSession: save failed code=\(failure.logCode, privacy: .public)")
            lastSaveError = failure
            if appendedAnchor {
                anchors.removeLast()
            }
            if let batchOffset {
                pendingBatchOffset = pendingBatchOffset.map { min($0, batchOffset) } ?? batchOffset
            }
            return false
        }

        lastSaveError = nil
        consecutiveSaveFailures = 0
        retryTask?.cancel()
        retryTask = nil
        persistedGeneration = generation
        lastSavedAt = timestamp
        return true
    }
}
