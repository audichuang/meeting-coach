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
        Self.run(meeting: meeting, recording: recording, transcription: transcription, summaries: summaries, settings: settings)
    }

    /// Whether `recording` was made with the coach, so a re-transcription should take this route too.
    static func isCoachRecording(_ recording: Recording, in meeting: Meeting) -> Bool {
        meeting.coachRecords.contains { $0.recordingID == recording.id }
    }

    /// Also the detail screen's (re)transcribe for a coach recording, which is how a run that
    /// failed after the meeting (offline, API error) is retried.
    static func run(meeting: Meeting, recording: Recording, transcription: TranscriptionCoordinator,
                    summaries: SummaryViewModel, settings: AppSettings) {
        guard let task = transcription.startTranscription(
            recording, language: .chinese, config: configuration(from: settings.pipelineConfiguration)
        ) else {
            AppLog.transcription.atNotice.notice("MeetingCoachFollowUp: formal transcript not started id=\(recording.id, privacy: .public)")
            return
        }
        Task { @MainActor in
            await task.value
            guard recording.transcript?.segments.isEmpty == false else { return }
            summaries.startSummary(for: meeting, provider: .openAI, model: CoachPricing.cardModel, template: .meetingCoach)
        }
    }
}
