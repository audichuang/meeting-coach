//
//  MeetingCoachFollowUpTests.swift
//  KurnTests
//
//  F1: every entry that (re)starts transcription of a coach recording uses the
//  coach configuration; the recap runs only after this run's formal transcript
//  is committed (including after pause/resume); a failed re-transcription never
//  triggers a recap from a stale transcript.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
@Suite("MeetingCoachFollowUp", .serialized)
struct MeetingCoachFollowUpTests {

    private static let regions = [
        SpeechRegion(start: 0.2, end: 1.2),
        SpeechRegion(start: 1.8, end: 2.8)
    ]

    @MainActor
    private final class Harness {
        let container: ModelContainer
        let context: ModelContext
        let settings: AppSettings
        let engines: FakeEngines
        let summaries: SummaryViewModel
        let transcription: TranscriptionCoordinator
        let followUp: MeetingCoachFollowUp
        let meeting: Meeting
        let recording: Recording
        let coachRecord: CoachRecord
        private let fileName: String

        init() throws {
            container = TestModelContainer.make()
            context = container.mainContext
            let defaults = try #require(UserDefaults(suiteName: "MeetingCoachFollowUpTests-\(UUID().uuidString)"))
            settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)
            settings.preprocessingEngine = .none
            settings.diarizationEngine = .heuristic
            settings.transcriptionEngine = .whisperAPI
            settings.transcriptionProviderID = AIProvider.openAI.id
            settings.recordCloudTranscriptionConsent(for: .openAI)

            engines = FakeEngines(regions: MeetingCoachFollowUpTests.regions)
            let llm = ScriptedLLMProvider(provider: .meetingCoach)
            summaries = SummaryViewModel(modelContext: context, appSettings: settings)
            let summariesRef = summaries
            transcription = TranscriptionCoordinator(
                modelContext: context,
                transcriptionService: TranscriptionService(engines: engines.catalog),
                onCoachTranscriptCommitted: { meeting, recording in
                    MeetingCoachFollowUp.finishAfterTranscript(
                        meeting: meeting,
                        recording: recording,
                        summaries: summariesRef,
                        resolveSummaryProvider: { _, _ in llm }
                    )
                }
            )
            followUp = MeetingCoachFollowUp(transcription: transcription, settings: settings)

            meeting = Meeting(title: "Coach Follow-Up", language: .english)
            context.insert(meeting)
            fileName = "coach-followup-\(UUID().uuidString).wav"
            let fixture = try AudioFixtures.wav(segments: [(220, 3.0)])
            let destination = try AudioFileStore.ensureRecordingsDirectory().appendingPathComponent(fileName)
            try FileManager.default.moveItem(at: fixture, to: destination)
            recording = Recording(meeting: meeting, fileName: fileName, duration: 60)
            context.insert(recording)
            coachRecord = CoachRecord(meeting: meeting, recordingID: recording.id, userName: "Tester")
            context.insert(coachRecord)
            try context.save()
        }

        deinit {
            AudioFileStore.delete(fileName: fileName)
        }

        func waitForCheckpoint() async {
            for _ in 0..<2_000 where recording.transcriptionCheckpointData == nil {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func settleFollowUp() async {
            await transcription.awaitActiveTranscriptions()
            for _ in 0..<20 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(5))
            }
            if let summaryTask = summaries.summaryTask {
                await summaryTask.value
            }
        }
    }

    @Test func resumingAPausedCoachRecordingUsesCoachConfigurationAndRunsRecap() async throws {
        let harness = try Harness()
        harness.engines.transcriber.holdAfterFirstChunk()

        harness.followUp.start(meeting: harness.meeting, recordingID: harness.recording.id)
        await harness.waitForCheckpoint()
        harness.transcription.cancelTranscription(harness.recording)
        await harness.settleFollowUp()

        #expect(harness.recording.transcriptionStatus == .pending)
        #expect(harness.coachRecord.costUSD == 0)
        #expect(harness.summaries.summaryTask == nil)
        #expect(harness.meeting.summaries.isEmpty)
        #expect(harness.summaries.error == nil)

        // Foreground / background resume via the coordinator's resume pass.
        harness.engines.transcriber.clearHold()
        harness.transcription.resumePendingTranscriptions(settings: harness.settings)
        await harness.settleFollowUp()

        #expect(harness.recording.transcriptionStatus == .done)
        let resumedRequest = try #require(harness.engines.transcriber.requests.last)
        #expect(resumedRequest.provider == .meetingCoach)
        #expect(resumedRequest.model == CoachPricing.transcribeModel)
        #expect(resumedRequest.language == .chinese)
        #expect(resumedRequest.taiwanMandarin == true)
        #expect(resumedRequest.resume?.completedChunks == 1)
        #expect(harness.coachRecord.costUSD > 0)
        #expect(harness.meeting.summaries.count == 1)
        #expect(harness.meeting.summaries.first?.providerRaw == AIProvider.meetingCoach.rawValue)
        #expect(harness.meeting.summaries.first?.model == CoachPricing.cardModel)
    }

    @Test func retranscribeAllUsesCoachConfigurationForCoachRecordings() async throws {
        let harness = try Harness()

        await harness.transcription.retranscribeAll(
            harness.meeting,
            language: harness.meeting.language,
            config: harness.settings.pipelineConfiguration
        )
        await harness.settleFollowUp()

        let request = try #require(harness.engines.transcriber.requests.first)
        #expect(request.provider == .meetingCoach)
        #expect(request.model == CoachPricing.transcribeModel)
        #expect(request.language == .chinese)
        #expect(request.taiwanMandarin == true)
        #expect(harness.meeting.summaries.count == 1)
    }

    @Test func directStartTranscriptionUsesCoachConfigurationForCoachRecordings() async throws {
        let harness = try Harness()

        harness.transcription.startTranscription(
            harness.recording,
            language: harness.meeting.language,
            config: harness.settings.pipelineConfiguration
        )
        await harness.settleFollowUp()

        let request = try #require(harness.engines.transcriber.requests.first)
        #expect(request.provider == .meetingCoach)
        #expect(request.model == CoachPricing.transcribeModel)
        #expect(request.language == .chinese)
        #expect(request.taiwanMandarin == true)
        #expect(harness.meeting.summaries.count == 1)
    }

    @Test func nonCoachRecordingKeepsGenericPipelineConfiguration() async throws {
        let harness = try Harness()
        harness.context.delete(harness.coachRecord)
        try harness.context.save()

        harness.transcription.startTranscription(
            harness.recording,
            language: harness.meeting.language,
            config: harness.settings.pipelineConfiguration
        )
        await harness.settleFollowUp()

        let request = try #require(harness.engines.transcriber.requests.first)
        #expect(request.provider == .openAI)
        #expect(request.language == .english)
        #expect(request.taiwanMandarin == false)
        #expect(harness.meeting.summaries.isEmpty)
    }

    @Test func failedRetranscriptionDoesNotTriggerRecapFromStaleTranscript() async throws {
        let harness = try Harness()
        let existing = Transcript(recording: harness.recording, language: "zh")
        existing.segments = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "old text")]
        harness.context.insert(existing)
        try harness.context.save()

        harness.engines.transcriber.setFailure(AppError.transcriptionFailed("network down"))
        harness.followUp.start(meeting: harness.meeting, recordingID: harness.recording.id)
        await harness.settleFollowUp()

        #expect(harness.recording.transcriptionStatus == .failed)
        #expect(harness.recording.transcript?.segments.map(\.text) == ["old text"])
        #expect(harness.coachRecord.costUSD == 0)
        #expect(harness.summaries.error == nil)
        #expect(harness.meeting.summaries.isEmpty)
    }

    /// Holds the first `summarize` call until released (or cancelled) so a test can
    /// submit coach recap requests while another summary is actively in flight.
    private final class GatedSummaryLLM: LLMProvider, @unchecked Sendable {
        let provider: AIProvider = .openAI
        private let lock = NSLock()
        private var _calls = 0
        private var continuation: CheckedContinuation<Void, Error>?
        private var released = false

        var callCount: Int { lock.withLock { _calls } }

        func release() {
            let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                released = true
                let current = continuation
                continuation = nil
                return current
            }
            cont?.resume()
        }

        func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
            let callIndex = lock.withLock { () -> Int in
                _calls += 1
                return _calls
            }
            if callIndex == 1 {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        enum Action { case wait, resume, cancel }
                        let action: Action = lock.withLock {
                            if Task.isCancelled { return .cancel }
                            if released { return .resume }
                            continuation = cont
                            return .wait
                        }
                        switch action {
                        case .wait: break
                        case .resume: cont.resume()
                        case .cancel: cont.resume(throwing: CancellationError())
                        }
                    }
                } onCancel: {
                    let cont = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                        let current = self.continuation
                        self.continuation = nil
                        return current
                    }
                    cont?.resume(throwing: CancellationError())
                }
                try Task.checkCancellation()
            }
            return SummaryResult(sections: [SummarySection(title: "Notes", items: ["manual summary"])])
        }

        func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
            throw AppError.transcriptionFailed("chat not scripted")
        }
    }

    private func insertTranscript(_ text: String, on recording: Recording, in context: ModelContext) {
        let transcript = Transcript(
            recording: recording,
            segments: [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: text)],
            language: "zh"
        )
        context.insert(transcript)
        recording.transcript = transcript
        recording.transcriptionStatus = .done
    }

    private func awaitAllSummaries(_ summaries: SummaryViewModel) async {
        while let task = summaries.summaryTask {
            await task.value
        }
    }

    @Test func coachRecapQueuedWhileAnotherSummaryRunsCompletesAfterIt() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let summaries = SummaryViewModel(modelContext: context)

        let meetingY = Meeting(title: "Meeting Y")
        context.insert(meetingY)
        let recordingY = Recording(meeting: meetingY, fileName: "y.m4a", duration: 30, transcriptionStatus: .done)
        context.insert(recordingY)
        insertTranscript("meeting Y transcript", on: recordingY, in: context)

        let meetingX = Meeting(title: "Meeting X")
        context.insert(meetingX)
        let recordingX = Recording(meeting: meetingX, fileName: "x.m4a", duration: 60, transcriptionStatus: .done)
        context.insert(recordingX)
        let coachRecordX = CoachRecord(meeting: meetingX, recordingID: recordingX.id, userName: "Tester")
        context.insert(coachRecordX)
        insertTranscript("meeting X formal transcript", on: recordingX, in: context)
        try context.save()

        let gatedLLM = GatedSummaryLLM()
        let coachLLM = ScriptedLLMProvider(provider: .meetingCoach)

        summaries.startSummary(
            for: meetingY,
            provider: .openAI,
            model: "gpt-4o",
            template: .general,
            resolveProvider: { _, _ in gatedLLM }
        )
        for _ in 0..<2_000 where gatedLLM.callCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(summaries.isSummarizing)

        MeetingCoachFollowUp.finishAfterTranscript(
            meeting: meetingX,
            recording: recordingX,
            summaries: summaries,
            resolveSummaryProvider: { _, _ in coachLLM }
        )

        gatedLLM.release()
        await awaitAllSummaries(summaries)

        #expect(meetingY.summaries.count == 1)
        #expect(meetingX.summaries.count == 1)
        #expect(meetingX.summaries.first?.providerRaw == AIProvider.meetingCoach.rawValue)
        #expect(coachLLM.summarizeCalls.count == 1)
        #expect(coachLLM.summarizeCalls.first?.userPrompt.contains("meeting X formal transcript") == true)
    }

    @Test func multipleCoachRecapsForSameMeetingWhileBusyCoalesceIntoOneWithLatestTranscripts() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let summaries = SummaryViewModel(modelContext: context)

        let meetingY = Meeting(title: "Meeting Y")
        context.insert(meetingY)
        let recordingY = Recording(meeting: meetingY, fileName: "y.m4a", duration: 30, transcriptionStatus: .done)
        context.insert(recordingY)
        insertTranscript("meeting Y transcript", on: recordingY, in: context)

        let meetingX = Meeting(title: "Meeting X")
        context.insert(meetingX)
        let recordingX1 = Recording(meeting: meetingX, fileName: "x1.m4a", duration: 60, transcriptionStatus: .done)
        let recordingX2 = Recording(meeting: meetingX, fileName: "x2.m4a", duration: 60, transcriptionStatus: .done)
        context.insert(recordingX1)
        context.insert(recordingX2)
        let coachRecord1 = CoachRecord(meeting: meetingX, recordingID: recordingX1.id, userName: "Tester")
        let coachRecord2 = CoachRecord(meeting: meetingX, recordingID: recordingX2.id, userName: "Tester")
        context.insert(coachRecord1)
        context.insert(coachRecord2)
        try context.save()

        let gatedLLM = GatedSummaryLLM()
        let coachLLM = ScriptedLLMProvider(provider: .meetingCoach)

        summaries.startSummary(
            for: meetingY,
            provider: .openAI,
            model: "gpt-4o",
            template: .general,
            resolveProvider: { _, _ in gatedLLM }
        )
        for _ in 0..<2_000 where gatedLLM.callCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        // Two coach transcripts for meeting X commit while meeting Y is summarizing.
        insertTranscript("segment A from recording 1", on: recordingX1, in: context)
        try context.save()
        MeetingCoachFollowUp.finishAfterTranscript(
            meeting: meetingX,
            recording: recordingX1,
            summaries: summaries,
            resolveSummaryProvider: { _, _ in coachLLM }
        )

        insertTranscript("segment B from recording 2", on: recordingX2, in: context)
        try context.save()
        MeetingCoachFollowUp.finishAfterTranscript(
            meeting: meetingX,
            recording: recordingX2,
            summaries: summaries,
            resolveSummaryProvider: { _, _ in coachLLM }
        )

        gatedLLM.release()
        await awaitAllSummaries(summaries)

        #expect(meetingY.summaries.count == 1)
        #expect(meetingX.summaries.count == 1)
        #expect(coachLLM.summarizeCalls.count == 1)
        let prompt = try #require(coachLLM.summarizeCalls.first?.userPrompt)
        #expect(prompt.contains("segment A from recording 1"))
        #expect(prompt.contains("segment B from recording 2"))
        #expect(coachRecord1.costUSD > 0)
        #expect(coachRecord2.costUSD > 0)
    }

    @Test func cancellingInFlightManualSummaryStillRunsQueuedCoachRecap() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let summaries = SummaryViewModel(modelContext: context)

        let meetingY = Meeting(title: "Meeting Y")
        context.insert(meetingY)
        let recordingY = Recording(meeting: meetingY, fileName: "y.m4a", duration: 30, transcriptionStatus: .done)
        context.insert(recordingY)
        insertTranscript("meeting Y transcript", on: recordingY, in: context)

        let meetingX = Meeting(title: "Meeting X")
        context.insert(meetingX)
        let recordingX = Recording(meeting: meetingX, fileName: "x.m4a", duration: 60, transcriptionStatus: .done)
        context.insert(recordingX)
        let coachRecordX = CoachRecord(meeting: meetingX, recordingID: recordingX.id, userName: "Tester")
        context.insert(coachRecordX)
        insertTranscript("meeting X transcript", on: recordingX, in: context)
        try context.save()

        let gatedLLM = GatedSummaryLLM()
        let coachLLM = ScriptedLLMProvider(provider: .meetingCoach)

        summaries.startSummary(
            for: meetingY,
            provider: .openAI,
            model: "gpt-4o",
            template: .general,
            resolveProvider: { _, _ in gatedLLM }
        )
        for _ in 0..<2_000 where gatedLLM.callCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        MeetingCoachFollowUp.finishAfterTranscript(
            meeting: meetingX,
            recording: recordingX,
            summaries: summaries,
            resolveSummaryProvider: { _, _ in coachLLM }
        )

        summaries.cancelSummary()
        await awaitAllSummaries(summaries)

        #expect(meetingY.summaries.isEmpty)
        #expect(meetingX.summaries.count == 1)
        #expect(coachLLM.summarizeCalls.count == 1)
    }

    @Test func deletingQueuedMeetingRemovesItsPendingCoachRecapWithoutCancellingActiveSummary() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let summaries = SummaryViewModel(modelContext: context)
        let library = MeetingLibrary(
            context: context,
            onMeetingsDeleted: { summaries.cancelSummaries(for: $0) }
        )

        let meetingY = Meeting(title: "Meeting Y")
        context.insert(meetingY)
        let recordingY = Recording(meeting: meetingY, fileName: "y.m4a", duration: 30, transcriptionStatus: .done)
        context.insert(recordingY)
        insertTranscript("meeting Y transcript", on: recordingY, in: context)

        let meetingX = Meeting(title: "Meeting X")
        context.insert(meetingX)
        let recordingX = Recording(meeting: meetingX, fileName: "x.m4a", duration: 60, transcriptionStatus: .done)
        context.insert(recordingX)
        context.insert(CoachRecord(meeting: meetingX, recordingID: recordingX.id, userName: "Tester"))
        insertTranscript("meeting X transcript", on: recordingX, in: context)
        try context.save()

        let gatedLLM = GatedSummaryLLM()
        let coachLLM = ScriptedLLMProvider(provider: .meetingCoach)

        summaries.startSummary(
            for: meetingY,
            provider: .openAI,
            model: "gpt-4o",
            template: .general,
            resolveProvider: { _, _ in gatedLLM }
        )
        for _ in 0..<2_000 where gatedLLM.callCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        MeetingCoachFollowUp.finishAfterTranscript(
            meeting: meetingX,
            recording: recordingX,
            summaries: summaries,
            resolveSummaryProvider: { _, _ in coachLLM }
        )

        // Delete the queued meeting while Meeting Y is still summarizing.
        try library.deleteMeeting(meetingX)
        #expect(summaries.isSummarizing)
        #expect(!summaries.isCancellingSummary)

        gatedLLM.release()
        await awaitAllSummaries(summaries)

        #expect(meetingY.summaries.count == 1)
        #expect(coachLLM.summarizeCalls.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Summary>()).count == 1)
    }

    @Test func bulkDeletingActiveAndQueuedMeetingsCancelsBothSummaries() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let summaries = SummaryViewModel(modelContext: context)
        let library = MeetingLibrary(
            context: context,
            onMeetingsDeleted: { summaries.cancelSummaries(for: $0) }
        )

        let meetingY = Meeting(title: "Meeting Y")
        context.insert(meetingY)
        let recordingY = Recording(meeting: meetingY, fileName: "y.m4a", duration: 30, transcriptionStatus: .done)
        context.insert(recordingY)
        insertTranscript("meeting Y transcript", on: recordingY, in: context)

        let meetingX = Meeting(title: "Meeting X")
        context.insert(meetingX)
        let recordingX = Recording(meeting: meetingX, fileName: "x.m4a", duration: 60, transcriptionStatus: .done)
        context.insert(recordingX)
        context.insert(CoachRecord(meeting: meetingX, recordingID: recordingX.id, userName: "Tester"))
        insertTranscript("meeting X transcript", on: recordingX, in: context)
        try context.save()

        let gatedLLM = GatedSummaryLLM()
        let coachLLM = ScriptedLLMProvider(provider: .meetingCoach)

        summaries.startSummary(
            for: meetingY,
            provider: .openAI,
            model: "gpt-4o",
            template: .general,
            resolveProvider: { _, _ in gatedLLM }
        )
        for _ in 0..<2_000 where gatedLLM.callCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        MeetingCoachFollowUp.finishAfterTranscript(
            meeting: meetingX,
            recording: recordingX,
            summaries: summaries,
            resolveSummaryProvider: { _, _ in coachLLM }
        )

        // Bulk delete cancels the running summary immediately without needing gatedLLM.release().
        try library.deleteMeetings([meetingY, meetingX])
        await awaitAllSummaries(summaries)

        #expect(coachLLM.summarizeCalls.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Summary>()).isEmpty)
        #expect(summaries.error == nil)
        #expect(!summaries.isSummarizing)
    }

    @Test func deletingMeetingMidFormalTranscriptionStopsChunksAndSkipsTranscriptAndRecap() async throws {
        let harness = try Harness()
        harness.engines.transcriber.pauseBeforeFirstCheckpoint()

        harness.followUp.start(meeting: harness.meeting, recordingID: harness.recording.id)
        for _ in 0..<2_000 where !harness.engines.transcriber.isPausedBeforeFirstCheckpoint {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(harness.engines.transcriber.isPausedBeforeFirstCheckpoint)

        try MeetingLibrary(context: harness.context).deleteMeeting(harness.meeting)
        harness.engines.transcriber.releaseFirstCheckpoint()
        await harness.settleFollowUp()

        #expect(!harness.engines.transcriber.didCompleteSecondChunk)
        #expect(try harness.context.fetch(FetchDescriptor<Transcript>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<Summary>()).isEmpty)
        #expect(harness.transcription.transcriptionError(for: harness.recording) == nil)
        #expect(!harness.summaries.isSummarizing)
    }

    @Test func deletingRecordingCancelsHeldFormalTranscriptionImmediately() async throws {
        let harness = try Harness()
        harness.engines.transcriber.holdAfterFirstChunk()
        let library = MeetingLibrary(
            context: harness.context,
            onMeetingsDeleted: { meetingIDs in
                harness.summaries.cancelSummaries(for: meetingIDs)
                harness.transcription.cancelWork(forDeletedMeetings: meetingIDs)
            },
            onRecordingsDeleted: { recordingIDs in
                harness.transcription.cancelWork(forDeletedRecordings: recordingIDs)
            }
        )

        harness.followUp.start(meeting: harness.meeting, recordingID: harness.recording.id)
        await harness.waitForCheckpoint()
        #expect(harness.transcription.isTranscribing(harness.recording))

        try library.deleteRecording(harness.recording)
        await harness.settleFollowUp()

        #expect(!harness.engines.transcriber.didCompleteSecondChunk)
        #expect(!harness.transcription.isTranscribing(harness.recording))
        #expect(try harness.context.fetch(FetchDescriptor<Transcript>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<Summary>()).isEmpty)
        #expect(harness.transcription.transcriptionError(for: harness.recording) == nil)
    }
}
