import Foundation

/// One contiguous speaker activity span emitted by an on-device streaming diarizer.
/// Times are recording-relative seconds aligned with the captured audio stream.
public struct LiveSpeakerSpan: Codable, Equatable, Sendable {
    public let speakerSlot: Int
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speakerSlot: Int, start: TimeInterval, end: TimeInterval) {
        self.speakerSlot = speakerSlot
        self.start = start
        self.end = end
    }
}

/// Accumulates streaming diarizer spans for a single meeting, maps each raw speaker
/// slot to a stable meeting-local anonymous label (`A`/`B`/`C`/`D` in order of first
/// appearance), and resolves the dominant speaker for any transcript time window.
public struct LiveSpeakerTimeline: Sendable {
    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)

    private var finalizedSpans: [LiveSpeakerSpan] = []
    private var tentativeSpans: [LiveSpeakerSpan] = []
    private var labelBySlot: [Int: String] = [:]

    public init() {}

    /// Append newly finalized spans and replace any previous tentative spans.
    /// Labels are assigned to unseen slots in chronological order of appearance.
    public mutating func ingest(finalized: [LiveSpeakerSpan], tentative: [LiveSpeakerSpan]) {
        let validFinalized = finalized.filter { $0.end > $0.start }
        let validTentative = tentative.filter { $0.end > $0.start }
        finalizedSpans.append(contentsOf: validFinalized)
        tentativeSpans = validTentative

        for span in (validFinalized + validTentative).sorted(by: { $0.start < $1.start }) {
            _ = label(for: span.speakerSlot)
        }
    }

    /// Returns the anonymous speaker label with the largest total overlap in `[start, end]`,
    /// or `nil` when no speaker span overlaps the interval.
    public func dominantSpeaker(from start: TimeInterval, to end: TimeInterval) -> String? {
        guard end > start else { return nil }
        var totals: [String: (overlap: TimeInterval, firstStart: TimeInterval)] = [:]
        for span in finalizedSpans + tentativeSpans {
            let overlapStart = max(start, span.start)
            let overlapEnd = min(end, span.end)
            let overlap = overlapEnd - overlapStart
            guard overlap > 0, let label = labelBySlot[span.speakerSlot] else { continue }
            if let existing = totals[label] {
                totals[label] = (existing.overlap + overlap, min(existing.firstStart, overlapStart))
            } else {
                totals[label] = (overlap, overlapStart)
            }
        }
        return totals.max { lhs, rhs in
            if lhs.value.overlap != rhs.value.overlap {
                return lhs.value.overlap < rhs.value.overlap
            }
            if lhs.value.firstStart != rhs.value.firstStart {
                return lhs.value.firstStart > rhs.value.firstStart
            }
            return lhs.key > rhs.key
        }?.key
    }

    public mutating func reset() {
        finalizedSpans.removeAll()
        tentativeSpans.removeAll()
        labelBySlot.removeAll()
    }

    private mutating func label(for slot: Int) -> String {
        if let existing = labelBySlot[slot] {
            return existing
        }
        let index = labelBySlot.count
        let assigned = index < Self.letters.count ? Self.letters[index] : "S\(index + 1)"
        labelBySlot[slot] = assigned
        return assigned
    }
}
