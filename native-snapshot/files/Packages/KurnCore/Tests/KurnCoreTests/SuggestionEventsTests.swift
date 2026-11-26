import Foundation
import Testing
@testable import KurnCore

struct SuggestionEventsTests {
    private func candidate() throws -> SuggestionCandidate {
        let evidence = try SuggestionEvidence(recordingID: UUID(), start: 5, end: 9, transcriptRevisionID: UUID(), context: "synthetic")
        return SuggestionCandidate(meetingID: UUID(), shortText: "risk", fullText: "Consider testing", reason: "different assumptions", evidence: [evidence], version: .init(model: "fixture", prompt: "v1", policy: "p1"))
    }
    private func event(_ l: SuggestionLedger, _ kind: SuggestionEventKind, _ t: TimeInterval) -> SuggestionEvent {
        SuggestionEvent(suggestionID: l.candidate.id, occurredAt: Date(timeIntervalSince1970: t), meetingOffset: t, kind: kind)
    }
    @Test func evidenceAndVersionRoundTrip() throws {
        let c = try candidate()
        let d = try JSONDecoder().decode(SuggestionCandidate.self, from: JSONEncoder().encode(c))
        #expect(d == c)
        #expect(d.evidence[0].start == 5 && d.evidence[0].end == 9)
        #expect(d.version.model == "fixture")
    }
    @Test func evidenceRejectsInvalidIntervals() {
        #expect(throws: SuggestionEventError.invalidEvidence) { try SuggestionEvidence(recordingID: UUID(), start: 3, end: 2, context: "x") }
        #expect(throws: SuggestionEventError.invalidEvidence) { try SuggestionEvidence(recordingID: UUID(), start: -1, end: 2, context: "x") }
        #expect(throws: SuggestionEventError.invalidEvidence) { try SuggestionEvidence(recordingID: UUID(), start: .nan, end: 2, context: "x") }
    }
    @Test func invalidDecodedEvidenceIsRejected() {
        let json = #"{"recordingID":"00000000-0000-0000-0000-000000000001","start":10,"end":2,"context":"x"}"#
        #expect(throws: SuggestionEventError.invalidEvidence) { try JSONDecoder().decode(SuggestionEvidence.self, from: Data(json.utf8)) }
    }
    @Test func shownExpandedDismissedAndFeedbackRoundTrip() throws {
        var l = try SuggestionLedger(candidate: candidate(), createdAt: Date(timeIntervalSince1970: 0), meetingOffset: 0)
        try l.append(event(l, .shown, 1)); try l.append(event(l, .expanded, 2))
        try l.append(event(l, .dismissed, 3)); try l.append(event(l, .feedback(value: "late"), 4))
        #expect(l.events.map(\.kind) == [.created, .shown, .expanded, .dismissed, .feedback(value: "late")])
        let decoded = try JSONDecoder().decode([SuggestionEvent].self, from: JSONEncoder().encode(l.events))
        #expect(try SuggestionLedger(candidate: l.candidate, restoring: decoded).events == l.events)
    }
    @Test func suppressedIsRetainedAndNotShown() throws {
        var l = try SuggestionLedger(candidate: candidate(), createdAt: Date(timeIntervalSince1970: 0), meetingOffset: 0)
        try l.append(event(l, .suppressed(reason: "minimum_gap"), 1))
        #expect(l.events.count == 2)
        #expect(throws: SuggestionEventError.invalidTransition) { try l.append(event(l, .shown, 2)) }
        #expect(throws: SuggestionEventError.invalidTransition) { try l.append(event(l, .feedback(value: "x"), 2)) }
    }
    @Test func rejectsInvalidTransitions() throws {
        var l = try SuggestionLedger(candidate: candidate(), createdAt: Date(timeIntervalSince1970: 0), meetingOffset: 0)
        #expect(throws: SuggestionEventError.invalidTransition) { try l.append(event(l, .expanded, 1)) }
        #expect(throws: SuggestionEventError.invalidTransition) { try l.append(event(l, .dismissed, 1)) }
        try l.append(event(l, .shown, 1))
        #expect(throws: SuggestionEventError.invalidTransition) { try l.append(event(l, .shown, 2)) }
        #expect(throws: SuggestionEventError.invalidTransition) { try l.append(event(l, .created, 2)) }
    }
    @Test func rejectsDuplicateWrongIDAndBackwardsTime() throws {
        var l = try SuggestionLedger(candidate: candidate(), createdAt: Date(timeIntervalSince1970: 1), meetingOffset: 1)
        let shown = event(l, .shown, 2); try l.append(shown)
        #expect(throws: SuggestionEventError.duplicateEvent) { try l.append(shown) }
        let wrong = SuggestionEvent(suggestionID: UUID(), occurredAt: Date(timeIntervalSince1970: 3), meetingOffset: 3, kind: .expanded)
        #expect(throws: SuggestionEventError.wrongSuggestion) { try l.append(wrong) }
        #expect(throws: SuggestionEventError.invalidTimestamp) { try l.append(event(l, .expanded, 1)) }
    }
    @Test func restorationRejectsInvalidOrder() throws {
        let c = try candidate()
        let bad = SuggestionEvent(suggestionID: c.id, occurredAt: .distantPast, meetingOffset: 0, kind: .shown)
        #expect(throws: SuggestionEventError.invalidTransition) { try SuggestionLedger(candidate: c, restoring: [bad]) }
    }
    @Test func throttleGapAndWindowBoundaries() throws {
        let gate = SuggestionThrottle()
        #expect(try gate.decide(at: 0, shownOffsets: []) == .show)
        #expect(try gate.decide(at: 89, shownOffsets: [0]) == .suppress(reason: "minimum_gap"))
        #expect(try gate.decide(at: 90, shownOffsets: [0]) == .show)
        #expect(try gate.decide(at: 599, shownOffsets: [0, 100, 200]) == .suppress(reason: "window_limit"))
        #expect(try gate.decide(at: 600, shownOffsets: [0, 100, 200]) == .show)
    }
    @Test func throttleRejectsInvalidTimes() {
        let gate = SuggestionThrottle()
        #expect(throws: SuggestionEventError.invalidTimestamp) { try gate.decide(at: 10, shownOffsets: [11]) }
        #expect(throws: SuggestionEventError.invalidTimestamp) { try gate.decide(at: .nan, shownOffsets: []) }
    }
}
