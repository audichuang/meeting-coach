//
//  CoachRecord.swift
//  Kurn
//
//  What the meeting coach kept for one recording: the cloud live transcript
//  (already converted to Traditional Chinese), the gaps it could not
//  transcribe, every suggestion ledger (shown or suppressed, with its events),
//  every trigger evaluation, the wrap-up and the spend. Collections are JSON
//  `Data`, the same convention `Transcript.segmentsData` uses.
//

import Foundation
import KurnCore
import SwiftData

/// A suggestion candidate and its append-only events, as persisted.
struct CoachLedgerRecord: Codable, Equatable {
    let candidate: SuggestionCandidate
    var events: [SuggestionEvent]
}

@Model
final class CoachRecord {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var recordingID: UUID?
    var createdAt: Date
    var userName: String = ""
    var segmentsData = Data()
    var gapsData = Data()
    var ledgersData = Data()
    var triggerLogData = Data()
    var wrapUpData: Data?
    var costUSD: Double = 0
    var transcribedSeconds: Double = 0
    /// Anonymous speaker label (e.g. "A"…"D") the user marked as themselves in this recording.
    /// Scoped strictly to this record; never copied to any other meeting.
    var selfSpeakerLabel: String?

    init(id: UUID = UUID(), meeting: Meeting, recordingID: UUID?, userName: String, createdAt: Date = Date()) {
        self.id = id
        self.meeting = meeting
        self.recordingID = recordingID
        self.userName = userName
        self.createdAt = createdAt
    }

    var segments: [LiveTranscriptSegment] {
        get { JSONStorage.decode([LiveTranscriptSegment].self, from: segmentsData) }
        set { segmentsData = JSONStorage.encode(newValue) }
    }

    var gaps: [LiveTranscriptGap] {
        get { JSONStorage.decode([LiveTranscriptGap].self, from: gapsData) }
        set { gapsData = JSONStorage.encode(newValue) }
    }

    var ledgers: [CoachLedgerRecord] {
        get { JSONStorage.decode([CoachLedgerRecord].self, from: ledgersData) }
        set { ledgersData = JSONStorage.encode(newValue) }
    }

    var triggerLog: [CoachTriggerRecord] {
        get { JSONStorage.decode([CoachTriggerRecord].self, from: triggerLogData) }
        set { triggerLogData = JSONStorage.encode(newValue) }
    }

    var wrapUp: CoachWrapUpArguments? {
        get { wrapUpData.flatMap { JSONStorage.decode(CoachWrapUpArguments.self, from: $0) } }
        set { wrapUpData = newValue.map { JSONStorage.encode($0) } }
    }
}
