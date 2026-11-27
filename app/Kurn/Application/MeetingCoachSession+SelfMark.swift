//
//  MeetingCoachSession+SelfMark.swift
//  Kurn
//
//  Meeting-local self-speaker marking ("本人標記") and late diarization backfill
//  for `MeetingCoachSession`.
//

import Foundation
import KurnCore

extension MeetingCoachSession {
    /// Mark an anonymous speaker label (e.g. "A") as the user for this recording,
    /// or pass `nil` to clear the mark. Persisted only on this recording's `CoachRecord`.
    func markSelfSpeaker(_ label: String?) {
        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (normalized?.isEmpty == false) ? normalized : nil
        guard selfSpeakerLabel != next else { return }
        selfSpeakerLabel = next
        save()
    }

    func clearSelfSpeaker() {
        markSelfSpeaker(nil)
    }

    func isSelfSpeaker(_ label: String?) -> Bool {
        guard let label, let selfSpeakerLabel else { return false }
        return label == selfSpeakerLabel
    }

    /// Backfills any live segments that arrived before streaming diarization
    /// produced an overlapping span. Never overwrites an already-assigned label.
    func refreshUnlabeledSegments() {
        guard !isCancelled, let speakerLookup else { return }
        var changed = false
        for index in segments.indices where segments[index].speakerLabel == nil {
            if let label = speakerLookup(segments[index].start, segments[index].end) {
                updateSegmentSpeakerLabel(at: index, to: label)
                changed = true
            }
        }
        if changed { save() }
    }
}
