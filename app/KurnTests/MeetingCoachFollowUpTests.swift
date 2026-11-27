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
}
