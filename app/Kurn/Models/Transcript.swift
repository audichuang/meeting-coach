//
//  Transcript.swift
//  Kurn
//
//  A full transcript for one recording. Speaker-attributed segments are encoded
//  to JSON `Data` because SwiftData cannot persist `[TranscriptSegment]` directly.
//

import Foundation
import Synchronization
import KurnCore
import SwiftData

@Model
final class Transcript {
    var id: UUID = UUID()
    var recording: Recording?
    /// JSON-encoded `[TranscriptSegment]`.
    var segmentsData: Data = Data()
    /// Detected BCP-47 locale, e.g. "pt-BR".
    var language: String = ""
    /// JSON-encoded `PipelineReport`: which engine each stage was asked for,
    /// which one ran, and whether it succeeded, degraded, was skipped or
    /// failed. Optional because transcripts written before H5 PR 11 have no
    /// report and because a run may legitimately produce none — `nil` means
    /// "unknown", never "clean".
    ///
    /// Only the closed vocabularies in `PipelineReport` are stored here: no
    /// provider message, file name, URL, or transcript text ever reaches this
    /// field, so it stays safe to export in a diagnostics bundle.
    var pipelineReportData: Data?
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        recording: Recording? = nil,
        segments: [TranscriptSegment] = [],
        language: String = "",
        pipelineReportData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.recording = recording
        // `?? Data()` only ever applies to the `= []` default here, which
        // trivially encodes; a real payload that fails to encode goes
        // through `TranscriptionCoordinator.saveTranscript`'s explicit
        // pre-check instead, which fails the save rather than reaching this
        // fallback. See `JSONStorage.encodeAuthoritative`.
        self.segmentsData = JSONStorage.encodeAuthoritative(segments) ?? Data()
        self.language = language
        self.pipelineReportData = pipelineReportData
        self.createdAt = createdAt
    }

    /// The stored run report, or `nil` when this transcript predates reporting
    /// or its bytes no longer decode — the two are indistinguishable to a
    /// reader, and both mean the same thing: nothing can be claimed about how
    /// the run went.
    var pipelineReport: PipelineReport? {
        guard let pipelineReportData else { return nil }
        return JSONStorage.decodeAuthoritative(PipelineReport.self, from: pipelineReportData).decodedValue
    }

    var segments: [TranscriptSegment] {
        get { decodedSegments.segments }
        // A failed encode leaves the previously-stored bytes untouched
        // rather than blanking them — losing a transcript to a rare
        // encoding failure on an in-place edit would be worse than keeping
        // the pre-edit content.
        set { segmentsData = JSONStorage.encodeAuthoritative(newValue) ?? segmentsData }
    }

    /// Whether the stored segments failed to decode or verify — distinct
    /// from a genuinely empty transcript, which `segments` alone cannot
    /// tell apart from corruption. Surfaced in `MeetingDetailView`'s
    /// transcript tab rather than rendered as "no speech detected".
    var isSegmentsDataCorrupted: Bool {
        decodedSegments.isUnreadable
    }

    /// Decoding is two JSON passes plus a checksum, and SwiftUI reads
    /// `segments` several times per render, which made a two-hour transcript
    /// stutter. Reuses the last decode while `segmentsData` is byte-identical.
    private var decodedSegments: DecodedSegments {
        let data = segmentsData
        if let hit = transcriptSegmentsCache.withLock({ $0[id] }), hit.data == data {
            return hit
        }
        let outcome = JSONStorage.decodeAuthoritative([TranscriptSegment].self, from: data)
        let entry = DecodedSegments(data: data, segments: outcome.decodedValue ?? [], isUnreadable: outcome.isUnreadable)
        transcriptSegmentsCache.withLock { cache in
            // shortcut: drop everything past a handful of transcripts; an LRU only if a screen ever shows more.
            if cache.count >= 8 { cache.removeAll() }
            cache[id] = entry
        }
        return entry
    }

    /// Flattened plain text, one line per segment, for sharing/export.
    var plainText: String {
        segments.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
    }
}

private struct DecodedSegments: Sendable {
    let data: Data
    let segments: [TranscriptSegment]
    let isUnreadable: Bool
}

private let transcriptSegmentsCache = Mutex<[UUID: DecodedSegments]>([:])
