//
//  AppCompositionTests.swift
//  KurnTests
//
//  The background transcription runner used to build its own view model with
//  no semantic-index or wiki coordinator, so a run finished in a
//  `BGProcessingTask` window was silently left unindexed. These pin the
//  wiring that replaced it: every coordinator gets its dependencies at
//  construction, from the one composition root both entry points share.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

private final class HoldingSummaryLLM: LLMProvider, @unchecked Sendable {
    let provider: AIProvider = .openAI
    private let lock = NSLock()
    private var _called = false
    var called: Bool { lock.withLock { _called } }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        lock.withLock { _called = true }
        try await Task.sleep(for: .seconds(3_600))
        return SummaryResult(sections: [SummarySection(title: "Notes", items: ["done"])])
    }

    func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
        throw AppError.transcriptionFailed("not scripted")
    }
}

@MainActor
struct AppCompositionTests {

    @Test func makeEnvironmentWiresEveryCoordinatorAtConstruction() throws {
        let container = TestModelContainer.make()
        let settings = try makeSettings()

        let environment = AppComposition.makeEnvironment(container: container, settings: settings)

        #expect(environment.modelContainer === container)
        #expect(environment.transcription.appSettings === settings)
        #expect(environment.transcription.semanticIndexCoordinator === environment.semanticIndex)
        #expect(environment.transcription.wikiCoordinator === environment.wiki)
        #expect(environment.semanticIndex.appSettings === settings)
        #expect(environment.wiki.appSettings === settings)
        #expect(environment.summaries.appSettings === settings)
        #expect(environment.summaries.modelContext === container.mainContext)
        #expect(environment.summaries.reviewPrompt === environment.reviewPrompt)
        #expect(environment.transcription.reviewPrompt === environment.reviewPrompt)
        #expect(environment.transcription.onCoachTranscriptCommitted != nil)
    }

    @Test func meetingLibraryDeleteCancelsRunningSummaryInEnvironment() async throws {
        let container = TestModelContainer.make()
        let settings = try makeSettings()
        let environment = AppComposition.makeEnvironment(container: container, settings: settings)
        let context = container.mainContext

        let meeting = Meeting(title: "Active summary")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "a.m4a", duration: 10, transcriptionStatus: .done)
        context.insert(recording)
        let transcript = Transcript(
            recording: recording,
            segments: [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "hello")],
            language: "en"
        )
        context.insert(transcript)
        recording.transcript = transcript
        try context.save()

        let llm = HoldingSummaryLLM()
        environment.summaries.startSummary(
            for: meeting,
            provider: .openAI,
            model: "gpt-4o",
            template: .general,
            resolveProvider: { _, _ in llm }
        )
        for _ in 0..<2_000 where !llm.called {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(environment.summaries.isSummarizing)

        try environment.meetingLibrary.deleteMeeting(meeting)
        await environment.summaries.summaryTask?.value

        #expect(!environment.summaries.isSummarizing)
        #expect(environment.summaries.error == nil)
        #expect(try context.fetch(FetchDescriptor<Summary>()).isEmpty)
    }

    @Test func eachCallBuildsIndependentCoordinators() throws {
        let container = TestModelContainer.make()
        let settings = try makeSettings()

        let first = AppComposition.makeEnvironment(container: container, settings: settings)
        let second = AppComposition.makeEnvironment(container: container, settings: settings)

        // `makeEnvironment` is pure wiring; sharing instances across entry
        // points is `AppComposition.environment(for:)`'s job, not this one's.
        #expect(first.transcription !== second.transcription)
        #expect(second.transcription.semanticIndexCoordinator === second.semanticIndex)
    }

    private func makeSettings() throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "AppCompositionTests-\(UUID().uuidString)"))
        return AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)
    }
}
