//
//  MeetingAudioImporter.swift
//  Kurn
//
//  Turns an audio file from outside the app — a Voice Memos share
//  (`IncomingFileInbox`) or a Files pick — into a new meeting with one
//  `Recording`, stored exactly like a captured one: an `.m4a` named by
//  `AudioFileStore.fileName(meetingID:recordingID:)` in the protected
//  recordings directory. Size totals, delete-all, launch recovery and the
//  upload MIME type all assume that extension, so other formats are
//  re-encoded to AAC first.
//
//  The slow part (copy or re-encode) goes to a temporary file. Moving it into
//  the recordings directory, validating it and inserting the row then happen
//  with no suspension point in between: `RecordingRecovery` runs on every
//  foreground activation and would attach a second row to an `.m4a` it found
//  there without one.
//
//  With the coach configured, the recording also gets an empty `CoachRecord`.
//  That is what marks a recording as the coach's everywhere
//  (`TranscriptionCoordinator.isCoachRecording`), so the formal transcript,
//  diarization and recap follow the coach route, on retries too. No live
//  suggestions exist for an import.
//

import AVFoundation
import Foundation
import KurnCore
import SwiftData
import UniformTypeIdentifiers

@MainActor
struct MeetingAudioImporter {
    typealias Transcode = @Sendable (URL, URL) async throws -> Void

    /// Re-encodes `source` to an AAC `.m4a` at `destination`.
    static let liveTranscode: Transcode = { source, destination in
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw AppError.audioError(NSLocalizedString("import_audio.error.unreadable", comment: "The file is not readable audio"))
        }
        try await session.export(to: destination, as: .m4a)
    }

    struct Imported {
        let meeting: Meeting
        let recordingID: UUID
        let isCoach: Bool
    }

    private let context: ModelContext
    private let language: MeetingLanguage
    /// The coach user's name when the coach can run; `nil` imports a plain recording.
    private let coachUserName: String?
    private let transcode: Transcode
    private let finalizer: RecordingFileFinalizing

    init(
        context: ModelContext,
        language: MeetingLanguage,
        coachUserName: String?,
        transcode: @escaping Transcode = MeetingAudioImporter.liveTranscode,
        finalizer: RecordingFileFinalizing = RecordingFileFinalizer()
    ) {
        self.context = context
        self.language = language
        self.coachUserName = coachUserName
        self.transcode = transcode
        self.finalizer = finalizer
    }

    /// The coach's user name when an import should take the coach route: the
    /// coach is on and the build can actually reach the Worker with a sign-in.
    static func coachUserName(settings: AppSettings) -> String? {
        guard let coach = MeetingCoachConfiguration.resolve(settings: settings),
              !coach.backend.notConfigured else { return nil }
        return coach.userName
    }

    /// Whether `url` is a local file this importer takes.
    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }

    func importAudio(from source: URL) async throws(AppError) -> Imported {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_import_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            if source.pathExtension.lowercased() == "m4a" {
                try FileManager.default.copyItem(at: source, to: temp)
            } else {
                try await transcode(source, temp)
            }
        } catch {
            throw (error as? AppError)
                ?? .audioError(NSLocalizedString("import_audio.error.unreadable", comment: "The file is not readable audio"))
        }

        // From here to the save there is no `await` (see the file header).
        let library = MeetingLibrary(context: context)
        let meeting = try library.createMeeting(title: Self.title(for: source), language: language)
        let recordingID = UUID()
        let fileName = AudioFileStore.fileName(meetingID: meeting.id, recordingID: recordingID)
        let metadata: FinalizedRecordingFile
        do {
            let directory = try AudioFileStore.ensureRecordingsDirectory()
            RecordingProtection.apply(to: temp)
            try FileManager.default.moveItem(at: temp, to: directory.appendingPathComponent(fileName))
            metadata = try finalizer.finalize(fileName: fileName)
        } catch {
            AudioFileStore.delete(fileName: fileName)
            try? library.discardNewMeeting(meeting)
            throw (error as? AppError)
                ?? .audioError(NSLocalizedString("import_audio.error.unreadable", comment: "The file is not readable audio"))
        }

        let recording = Recording(
            id: recordingID, meeting: meeting, fileName: fileName,
            duration: metadata.duration, fileSize: metadata.fileSize
        )
        context.insert(recording)
        var coachRecord: CoachRecord?
        if let coachUserName {
            let record = CoachRecord(meeting: meeting, recordingID: recordingID, userName: coachUserName)
            context.insert(record)
            coachRecord = record
        }
        if let failure = context.saveOrError() {
            context.delete(recording)
            if let coachRecord { context.delete(coachRecord) }
            AudioFileStore.delete(fileName: fileName)
            try? library.discardNewMeeting(meeting)
            throw failure
        }
        return Imported(meeting: meeting, recordingID: recordingID, isCoach: coachRecord != nil)
    }

    /// The file's own name; empty lets `createMeeting` fall back to the dated default title.
    static func title(for source: URL) -> String {
        source.deletingPathExtension().lastPathComponent
    }
}
