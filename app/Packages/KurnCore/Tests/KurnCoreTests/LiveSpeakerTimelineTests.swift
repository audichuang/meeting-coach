import Foundation
import Testing
@testable import KurnCore

struct LiveSpeakerTimelineTests {
    @Test func dominantSpeakerSelectsLabelWithLargestTimeOverlap() {
        var timeline = LiveSpeakerTimeline()
        timeline.ingest(
            finalized: [
                LiveSpeakerSpan(speakerSlot: 0, start: 0, end: 6),
                LiveSpeakerSpan(speakerSlot: 1, start: 6, end: 18),
                LiveSpeakerSpan(speakerSlot: 0, start: 18, end: 20)
            ],
            tentative: []
        )

        // Slot 0 appeared first -> "A" (8 s overlap); slot 1 appeared second -> "B" (12 s overlap).
        #expect(timeline.dominantSpeaker(from: 0, to: 20) == "B")
        #expect(timeline.dominantSpeaker(from: 0, to: 6) == "A")
        #expect(timeline.dominantSpeaker(from: 18, to: 20) == "A")
    }

    @Test func assignsAnonymousLettersInOrderOfFirstAppearance() {
        var timeline = LiveSpeakerTimeline()
        timeline.ingest(
            finalized: [
                LiveSpeakerSpan(speakerSlot: 3, start: 1, end: 4),
                LiveSpeakerSpan(speakerSlot: 1, start: 5, end: 8),
                LiveSpeakerSpan(speakerSlot: 0, start: 9, end: 12),
                LiveSpeakerSpan(speakerSlot: 2, start: 13, end: 16)
            ],
            tentative: []
        )

        #expect(timeline.dominantSpeaker(from: 1, to: 4) == "A")
        #expect(timeline.dominantSpeaker(from: 5, to: 8) == "B")
        #expect(timeline.dominantSpeaker(from: 9, to: 12) == "C")
        #expect(timeline.dominantSpeaker(from: 13, to: 16) == "D")
    }

    @Test func sumsDisjointSpansOfSameSpeakerBeforeComparing() {
        var timeline = LiveSpeakerTimeline()
        timeline.ingest(
            finalized: [
                LiveSpeakerSpan(speakerSlot: 0, start: 0, end: 4),
                LiveSpeakerSpan(speakerSlot: 1, start: 4, end: 11),
                LiveSpeakerSpan(speakerSlot: 0, start: 11, end: 16)
            ],
            tentative: []
        )

        // Speaker A: 4 + 5 = 9 s; Speaker B: 7 s -> A wins.
        #expect(timeline.dominantSpeaker(from: 0, to: 16) == "A")
    }

    @Test func tentativeSpansContributeUntilReplacedByLaterUpdate() {
        var timeline = LiveSpeakerTimeline()
        timeline.ingest(
            finalized: [LiveSpeakerSpan(speakerSlot: 0, start: 0, end: 5)],
            tentative: [LiveSpeakerSpan(speakerSlot: 1, start: 5, end: 12)]
        )
        #expect(timeline.dominantSpeaker(from: 5, to: 12) == "B")

        // Next update replaces tentative spans and finalizes the corrected turn.
        timeline.ingest(
            finalized: [LiveSpeakerSpan(speakerSlot: 0, start: 5, end: 12)],
            tentative: []
        )
        #expect(timeline.dominantSpeaker(from: 5, to: 12) == "A")
    }

    @Test func returnsNilWhenNoSpanOverlapsOrTimelineIsEmpty() {
        var timeline = LiveSpeakerTimeline()
        #expect(timeline.dominantSpeaker(from: 0, to: 10) == nil)

        timeline.ingest(
            finalized: [LiveSpeakerSpan(speakerSlot: 0, start: 20, end: 30)],
            tentative: []
        )
        #expect(timeline.dominantSpeaker(from: 0, to: 15) == nil)
        #expect(timeline.dominantSpeaker(from: 20, to: 20) == nil)
    }
}
