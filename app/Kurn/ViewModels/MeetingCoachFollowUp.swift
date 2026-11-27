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
//  It lives in ViewModels/ because it drives `SummaryViewModel`, which owns
//  summary persistence and the Summary tab's progress state.
//

import Foundation
import KurnCore

@MainActor
final class MeetingCoachFollowUp {
    nonisolated static let transcriptionModel = "gpt-transcribe"

    private let transcription: TranscriptionCoordinator
    private let summaries: SummaryViewModel
    private let settings: AppSettings

    init(transcription: TranscriptionCoordinator, summaries: SummaryViewModel, settings: AppSettings) {
        self.transcription = transcription
        self.summaries = summaries
        self.settings = settings
    }

    /// The pipeline for the formal transcript: the user's own stages, with the
    /// transcription step pinned to OpenAI. Cloud consent is implied — the coach
    /// already streamed this audio to OpenAI while recording.
    nonisolated static func configuration(from base: PipelineConfiguration) -> PipelineConfiguration {
        var config = base
        config.transcription = .whisperAPI
        config.transcriptionProvider = .openAI
        config.transcriptionModel = transcriptionModel
        config.cloudTranscriptionConsented = true
        config.taiwanMandarinTranscript = true
        config.correction = .none
        return config
    }

    func start(meeting: Meeting, recordingID: UUID) {
        guard let recording = meeting.recordings.first(where: { $0.id == recordingID }) else { return }
        guard let task = transcription.startTranscription(
            recording, language: .chinese, config: Self.configuration(from: settings.pipelineConfiguration)
        ) else {
            AppLog.transcription.atNotice.notice("MeetingCoachFollowUp: formal transcript not started id=\(recordingID, privacy: .public)")
            return
        }
        Task { [weak self] in
            await task.value
            guard let self, recording.transcript?.segments.isEmpty == false else { return }
            self.summaries.startSummary(for: meeting, provider: .openAI, model: CoachPricing.cardModel, template: .meetingCoach)
        }
    }
}
