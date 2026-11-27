//
//  MeetingCoachFollowUp.swift
//  Kurn
//
//  After a meeting-coach recording is saved: transcribe the whole recording
//  again with `gpt-transcribe` (Traditional-Chinese prompt, output converted
//  to Traditional) into the recording's `Transcript` — the formal transcript
//  that summary, detail and export read, which also covers any live gaps —
//  then write the post-meeting summary with the card model. The live
//  transcript stays in `CoachRecord` as the original.
//
//  Both calls run under `AIProvider.meetingCoach`, i.e. through the Worker
//  (or, in DEBUG, straight to OpenAI), and their spend is added to the
//  recording's `CoachRecord.costUSD` so the meeting's coach spend is complete.
//
//  It lives in ViewModels/ because it drives `SummaryViewModel`, which owns
//  summary persistence and the Summary tab's progress state.
//

import Foundation
import KurnCore
import SwiftData

@MainActor
final class MeetingCoachFollowUp {
    nonisolated static let transcriptionModel = CoachPricing.transcribeModel

    private let transcription: TranscriptionCoordinator
    private let settings: AppSettings

    init(transcription: TranscriptionCoordinator, settings: AppSettings) {
        self.transcription = transcription
        self.settings = settings
    }

    /// The pipeline for the formal transcript: the user's own stages, with the
    /// transcription step pinned to the coach's backend. Cloud consent is implied — the coach
    /// already streamed this audio to OpenAI while recording.
    nonisolated static func configuration(from base: PipelineConfiguration) -> PipelineConfiguration {
        base.forMeetingCoach
    }

    func start(meeting: Meeting, recordingID: UUID) {
        guard let recording = meeting.recordings.first(where: { $0.id == recordingID }) else { return }
        if transcription.startTranscription(
            recording, language: .chinese, config: Self.configuration(from: settings.pipelineConfiguration)
        ) == nil {
            AppLog.transcription.atNotice.notice("MeetingCoachFollowUp: formal transcript not started id=\(recording.id, privacy: .public)")
        }
    }

    /// Whether `recording` was made with the coach, so a re-transcription should take this route too.
    static func isCoachRecording(_ recording: Recording, in meeting: Meeting) -> Bool {
        meeting.coachRecords.contains { $0.recordingID == recording.id }
    }

    /// Called by `TranscriptionCoordinator.onCoachTranscriptCommitted` once this run's formal
    /// transcript has been committed — including when that happens later via resume or retry.
    static func finishAfterTranscript(
        meeting: Meeting,
        recording: Recording,
        summaries: SummaryViewModel,
        resolveSummaryProvider: ProviderFactory.LLMResolver? = nil
    ) {
        let recordingID = recording.id
        let record = meeting.coachRecords.first { $0.recordingID == recordingID }
            ?? (try? recording.modelContext?.fetch(
                FetchDescriptor<CoachRecord>(predicate: #Predicate { $0.recordingID == recordingID })
            ))?.first
        let recordID = record?.id
        let context = recording.modelContext
        // shortcut: bills the whole recording at the list price; a resumed run that skipped
        // chunks is overcounted. Upgrade by summing the `usage.seconds` each chunk reports.
        let recordSpend: @MainActor (Double) -> Void = { addSpend($0, toRecordID: recordID, in: context) }
        recordSpend(recording.duration / 60 * CoachPricing.transcribePerMinute)
        let resolver: ProviderFactory.LLMResolver = resolveSummaryProvider ?? { _, model in
            let backend = CoachBackend.current()
            try backend?.requireReady()
            try LLMHTTP.requireAPIKey(backend?.token ?? "", provider: .meetingCoach)
            guard let backend else { throw AppError.invalidProviderURL }
            return CoachSummaryProvider(client: CoachResponsesClient(backend: backend), model: model) { usage in
                var meter = CoachCostMeter()
                meter.addTokens(model: model, usage: usage)
                Task { await recordSpend(meter.totalUSD) }
            }
        }
        summaries.enqueueCoachSummary(
            for: meeting, provider: .meetingCoach, model: CoachPricing.cardModel, template: .meetingCoach,
            resolveProvider: resolver
        )
    }

    private static func addSpend(_ usd: Double, toRecordID recordID: UUID?, in context: ModelContext?) {
        guard let recordID, let context, usd > 0 else { return }
        let descriptor = FetchDescriptor<CoachRecord>(predicate: #Predicate { $0.id == recordID })
        guard let record = try? context.fetch(descriptor).first, !record.isDeleted else { return }
        record.costUSD += usd
        if let failure = context.saveOrError() {
            AppLog.persistence.atError.error("MeetingCoachFollowUp: spend save failed code=\(failure.logCode, privacy: .public)")
        }
    }
}
