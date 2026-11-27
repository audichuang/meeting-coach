import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct CrossMeetingSpeakerMatchTests {
    @Test func namedSyntheticSpeakerIsNotACandidate() throws {
        let context = ModelContext(TestModelContainer.make())
        let previous = Meeting(title: "Synthetic previous")
        let current = Meeting(title: "Synthetic current")
        context.insert(previous); context.insert(current)
        let old = Speaker(meeting: previous, label: "Speaker 1", name: "Synthetic", color: "#FFFFFF", voiceprintData: VectorData.encode([1, 0]))
        context.insert(old); try context.save()
        let coordinator = TranscriptionCoordinator(modelContext: context)
        #expect(coordinator.crossMeetingSpeakerCandidates(excluding: current).isEmpty)
    }
    @Test func directStageDoesNotOfferIdentity() {
        let context = ModelContext(TestModelContainer.make())
        let coordinator = TranscriptionCoordinator(modelContext: context)
        let old = Speaker(label: "Speaker 1", name: "Synthetic", color: "#FFFFFF")
        let new = Speaker(label: "Speaker 1", color: "#FFFFFF")
        coordinator.stageCrossMeetingMatchIfPossible(for: new, voiceprint: [1, 0], among: [(value: old, voiceprint: [1, 0])])
        #expect(coordinator.pendingCrossMeetingMatches.isEmpty)
        #expect(new.name.isEmpty)
    }
    @Test func staleMatchCannotApplyIdentity() {
        let context = ModelContext(TestModelContainer.make())
        let coordinator = TranscriptionCoordinator(modelContext: context)
        let old = Speaker(label: "Speaker 1", name: "Synthetic", color: "#FFFFFF")
        let new = Speaker(label: "Speaker 1", color: "#FFFFFF")
        let match = TranscriptionCoordinator.CrossMeetingSpeakerMatch(newSpeaker: new, matchedSpeaker: old, matchedMeetingTitle: "Synthetic")
        coordinator.applyCrossMeetingMatch(match)
        #expect(new.name.isEmpty)
    }
}
