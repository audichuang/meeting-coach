//
//  SummaryViewModelStateTests.swift
//  KurnTests
//
//  `SummaryViewModel.startSummary`/`cancelSummary` over a
//  `SummaryService` whose LLM is a scripted `LLMProvider` (no keychain, no
//  network): the `isSummarizing`/`isCancellingSummary` flags, what gets
//  persisted on success, how a provider failure surfaces, that cancellation
//  is silent, and that a run with no transcript text never reaches the LLM.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
@Suite("SummaryViewModel state")
struct SummaryViewModelStateTests {

    private final class ScriptedLLM: LLMProvider, @unchecked Sendable {
        let provider: AIProvider = .openAI
        private let lock = NSLock()
        private var _calls = 0
        private var _failure: Error?
        private var _holds = false
        private var _pauseFirstCall = false
        private var _firstCallReleased = false
        private var _firstCallContinuation: CheckedContinuation<Void, Never>?

        var calls: Int { lock.withLock { _calls } }
        func fail(with error: Error) { lock.withLock { _failure = error } }
        func holdUntilCancelled() { lock.withLock { _holds = true } }
        func pauseFirstCall() { lock.withLock { _pauseFirstCall = true } }

        func releaseFirstCall() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                _firstCallReleased = true
                let current = _firstCallContinuation
                _firstCallContinuation = nil
                return current
            }
            continuation?.resume()
        }

        func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
            let (callIndex, failure, holds, pauseFirst) = lock.withLock {
                _calls += 1
                return (_calls, _failure, _holds, _pauseFirstCall)
            }
            if callIndex == 1 && pauseFirst {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let alreadyReleased = lock.withLock { () -> Bool in
                        if _firstCallReleased { return true }
                        _firstCallContinuation = continuation
                        return false
                    }
                    if alreadyReleased { continuation.resume() }
                }
            }
            if holds { try await Task.sleep(for: .seconds(3_600)) }
            if let failure { throw failure }
            return SummaryResult(sections: [SummarySection(title: "Decisions", items: ["ship it"])])
        }

        func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
            throw AppError.transcriptionFailed("chat is not scripted")
        }
    }

    @MainActor
    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        let llm: ScriptedLLM
        let viewModel: SummaryViewModel
        let meeting: Meeting
        let reviewPrompt: ReviewPromptCoordinator

        init(
            withTranscript: Bool = true,
            segments: [TranscriptSegment]? = nil,
            resolveBudget: @escaping ContextBudget.Resolver = ContextBudget.live
        ) throws {
            container = TestModelContainer.make()
            context = container.mainContext
            llm = ScriptedLLM()
            let scripted = llm
            let defaults = try #require(UserDefaults(suiteName: "SummaryViewModelStateTests.\(UUID().uuidString)"))
            reviewPrompt = ReviewPromptCoordinator(defaults: defaults, appVersion: "1.0.0", isSuppressed: { false })
            viewModel = SummaryViewModel(
                modelContext: context,
                reviewPrompt: reviewPrompt,
                summaryService: SummaryService(resolveProvider: { _, _ in scripted }, resolveBudget: resolveBudget)
            )
            meeting = Meeting(title: "Summary")
            context.insert(meeting)
            let recording = Recording(meeting: meeting, fileName: "s.m4a", duration: 12, transcriptionStatus: .done)
            context.insert(recording)
            if withTranscript {
                let transcript = Transcript(
                    recording: recording,
                    segments: segments ?? [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "we ship")],
                    language: "en"
                )
                context.insert(transcript)
                recording.transcript = transcript
            }
            try context.save()
        }

        func start() {
            viewModel.startSummary(for: meeting, provider: .openAI, model: "gpt-4o", template: .general)
        }

        func awaitSummary() async {
            await viewModel.summaryTask?.value
        }

        func waitUntilLLMCalled() async {
            for _ in 0..<2_000 where llm.calls == 0 {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @Test func successPersistsASummaryAndClearsTheRunFlags() async throws {
        let harness = try Harness()

        harness.start()
        #expect(harness.viewModel.isSummarizing)
        await harness.awaitSummary()

        #expect(!harness.viewModel.isSummarizing)
        #expect(!harness.viewModel.isCancellingSummary)
        #expect(harness.viewModel.summaryTask == nil)
        #expect(harness.viewModel.error == nil)
        #expect(harness.meeting.summaries.count == 1)
        #expect(harness.meeting.summaries.first?.sections.first?.items == ["ship it"])
        #expect(harness.meeting.summaries.first?.provider == .openAI)
        #expect(harness.meeting.summaries.first?.model == "gpt-4o")
        #expect(harness.meeting.summaryMapCheckpointData == nil)
        #expect(harness.llm.calls == 1)
        #expect(harness.reviewPrompt.state.successfulMoments == 1)
    }

    @Test func theDraftIsShownOnlyWhileARunIsInFlightAndNeverGoesBackwards() async throws {
        let harness = try Harness()
        let vm = harness.viewModel
        vm.recordSummaryDraft(SummaryDraftSnapshot(sequence: 1, text: "early", words: 1))
        #expect(vm.summaryDraft.isEmpty)

        harness.llm.holdUntilCancelled()
        harness.start()
        #expect(vm.summaryRequestStartedAt != nil)
        await harness.waitUntilLLMCalled()
        // Let the run's own opening (empty) draft land before scripting updates.
        try await Task.sleep(for: .milliseconds(50))

        vm.recordSummaryDraft(SummaryDraftSnapshot(sequence: 10, text: "Decisions\nwe", words: 2))
        #expect(vm.summaryDraft == "Decisions\nwe")
        #expect(vm.summaryWordsReceived == 2)

        // An older snapshot landing late is ignored.
        vm.recordSummaryDraft(SummaryDraftSnapshot(sequence: 9, text: "Deci", words: 1))
        #expect(vm.summaryDraft == "Decisions\nwe")

        // A new staged request opens with an empty draft and restarts the timer.
        let before = try #require(vm.summaryRequestStartedAt)
        try await Task.sleep(for: .milliseconds(10))
        vm.recordSummaryDraft(SummaryDraftSnapshot(sequence: 11, text: "", words: 0))
        #expect(vm.summaryDraft.isEmpty)
        #expect(vm.summaryWordsReceived == nil)
        #expect(try #require(vm.summaryRequestStartedAt) > before)

        vm.cancelSummary()
        await harness.awaitSummary()
        #expect(vm.summaryDraft.isEmpty)
        #expect(vm.summaryRequestStartedAt == nil)
    }

    @Test func providerFailureSurfacesTheAppErrorAndPersistsNothing() async throws {
        let harness = try Harness()
        harness.llm.fail(with: AppError.noAPIKey(provider: "OpenAI"))

        harness.start()
        await harness.awaitSummary()

        guard case .noAPIKey = harness.viewModel.error else {
            Issue.record("expected the provider's AppError to surface")
            return
        }
        #expect(!harness.viewModel.isSummarizing)
        #expect(harness.meeting.summaries.isEmpty)
    }

    @Test func nonAppErrorIsWrappedAsAnAPIError() async throws {
        let harness = try Harness()
        harness.llm.fail(with: URLError(.badServerResponse))

        harness.start()
        await harness.awaitSummary()

        guard case .apiError(let statusCode, _) = harness.viewModel.error else {
            Issue.record("expected an apiError wrapper")
            return
        }
        #expect(statusCode == 0)
        #expect(harness.meeting.summaries.isEmpty)
    }

    @Test func meetingWithoutTranscriptFailsBeforeReachingTheLLM() async throws {
        let harness = try Harness(withTranscript: false)

        harness.start()
        await harness.awaitSummary()

        guard case .transcriptionFailed = harness.viewModel.error else {
            Issue.record("expected the no-transcript error")
            return
        }
        #expect(harness.llm.calls == 0)
        #expect(harness.meeting.summaries.isEmpty)
    }

    @Test func cancelIsSilentAndPersistsNothing() async throws {
        let harness = try Harness()
        harness.llm.holdUntilCancelled()

        harness.start()
        await harness.waitUntilLLMCalled()
        harness.viewModel.cancelSummary()
        #expect(harness.viewModel.isCancellingSummary)
        await harness.awaitSummary()

        #expect(!harness.viewModel.isSummarizing)
        #expect(!harness.viewModel.isCancellingSummary)
        #expect(harness.viewModel.error == nil)
        #expect(harness.meeting.summaries.isEmpty)
    }

    @Test func secondStartWhileRunningIsIgnoredAndCancelWithoutRunIsANoOp() async throws {
        let harness = try Harness()
        harness.viewModel.cancelSummary()
        #expect(!harness.viewModel.isCancellingSummary)

        harness.llm.holdUntilCancelled()
        harness.start()
        await harness.waitUntilLLMCalled()
        let first = harness.viewModel.summaryTask
        harness.start()
        #expect(harness.viewModel.summaryTask == first)

        harness.viewModel.cancelSummary()
        await harness.awaitSummary()
        #expect(harness.llm.calls == 1)
    }

    @Test func deletingMeetingMidStagedSummaryStopsMapRunnerAndWritesNothing() async throws {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 10, text: "alpha discussion about architecture roadmap and milestones"),
            TranscriptSegment(speakerLabel: "Speaker 2", startTime: 10, endTime: 20, text: "beta discussion about delivery schedule and release risks"),
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 20, endTime: 30, text: "gamma discussion about testing coverage and final signoff")
        ]
        let harness = try Harness(
            segments: segments,
            resolveBudget: { _, _ in ContextBudget(inputTokens: 15, mapBlockTokens: 10) }
        )
        harness.llm.pauseFirstCall()

        harness.start()
        await harness.waitUntilLLMCalled()

        try MeetingLibrary(context: harness.context).deleteMeeting(harness.meeting)
        harness.llm.releaseFirstCall()
        await harness.awaitSummary()

        #expect(harness.llm.calls == 1)
        #expect(try harness.context.fetch(FetchDescriptor<Summary>()).isEmpty)
        #expect(harness.viewModel.error == nil)
        #expect(!harness.viewModel.isSummarizing)
        #expect(harness.reviewPrompt.state.successfulMoments == 0)
    }

    @Test func deletingMeetingMidSinglePassSummaryWritesNoSummary() async throws {
        let harness = try Harness()
        harness.llm.pauseFirstCall()

        harness.start()
        await harness.waitUntilLLMCalled()

        try MeetingLibrary(context: harness.context).deleteMeeting(harness.meeting)
        harness.llm.releaseFirstCall()
        await harness.awaitSummary()

        #expect(try harness.context.fetch(FetchDescriptor<Summary>()).isEmpty)
        #expect(harness.viewModel.error == nil)
        #expect(!harness.viewModel.isSummarizing)
        #expect(harness.reviewPrompt.state.successfulMoments == 0)
    }
}
