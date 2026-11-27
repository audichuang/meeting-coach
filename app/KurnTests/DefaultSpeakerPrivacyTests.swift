import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct DefaultSpeakerPrivacyTests {
    @Test func existingNamedVoiceIsNotOfferedAcrossMeetings() throws {
        let context = ModelContext(TestModelContainer.make())
        let first = Meeting(title: "Synthetic A")
        let second = Meeting(title: "Synthetic B")
        context.insert(first)
        context.insert(second)
        let old = Speaker(meeting: first, label: "Speaker 1", name: "Synthetic Name", color: "#FFFFFF", voiceprintData: VectorData.encode([1, 0]))
        context.insert(old)
        let coordinator = TranscriptionCoordinator(modelContext: context)
        try context.save()
        #expect(coordinator.crossMeetingSpeakerCandidates(excluding: second).isEmpty)
        let incoming = Speaker(meeting: second, label: "Speaker 1", color: "#FFFFFF")
        context.insert(incoming)
        coordinator.stageCrossMeetingMatchIfPossible(for: incoming, voiceprint: [1, 0], among: [(value: old, voiceprint: [1, 0])])
        #expect(coordinator.pendingCrossMeetingMatches.isEmpty)
        #expect(incoming.name.isEmpty)
    }

    @Test func namedLegacyRowIsNotShownAsAutomaticIdentity() {
        let speaker = Speaker(label: "Speaker 1", name: "Synthetic Name", color: "#FFFFFF")
        #expect(speaker.displayName == "Speaker 1")
    }
}
