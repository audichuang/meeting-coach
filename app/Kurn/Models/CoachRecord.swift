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
    /// `CoachCostBreakdown` JSON; nil until something is spent (schema 1.7.0).
    var costBreakdownData: Data?
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

    /// Spend per step; nil for a record that spent before steps were tracked, whose
    /// total cannot be split.
    var costBreakdown: CoachCostBreakdown? {
        if let costBreakdownData { return JSONStorage.decode(CoachCostBreakdown.self, from: costBreakdownData) }
        return costUSD == 0 ? CoachCostBreakdown() : nil
    }

    /// The one way spend is recorded, so the total and the steps move together.
    func addCost(_ delta: CoachCostBreakdown) {
        let usd = delta.totalUSD
        guard usd != 0 else { return }
        let breakdown = costBreakdown
        costUSD += usd
        if let breakdown { costBreakdownData = JSONStorage.encode(breakdown + delta) }
    }

    func addCost(_ usd: Double, to step: CoachCostStep) {
        var delta = CoachCostBreakdown()
        delta[step] = usd
        addCost(delta)
    }

    var wrapUp: CoachWrapUpArguments? {
        get { wrapUpData.flatMap { JSONStorage.decode(CoachWrapUpArguments.self, from: $0) } }
        set { wrapUpData = newValue.map { JSONStorage.encode($0) } }
    }
}

extension Meeting {
    /// The coach's estimated spend over every recording of this meeting.
    var coachCostUSD: Double { coachRecords.reduce(0) { $0 + $1.costUSD } }

    /// Per step over every recording; nil when any recording's spend cannot be split.
    var coachCostBreakdown: CoachCostBreakdown? { CoachCostBreakdown.sum(coachRecords.map(\.costBreakdown)) }
}
