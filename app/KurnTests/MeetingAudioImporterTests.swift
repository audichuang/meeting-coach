//
//  MeetingAudioImporterTests.swift
//  KurnTests
//
//  An imported audio file becomes a new meeting with one ready `.m4a`
//  recording in the protected store; a coach import also gets the empty
//  `CoachRecord` that routes the follow-up through the coach pipeline; an
//  unreadable file leaves neither a meeting nor a file behind. Synthetic
//  tones only.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
@Suite(.serialized)
struct MeetingAudioImporterTests {

    private func recordingFiles(of context: ModelContext) -> [String] {
        ((try? context.fetch(FetchDescriptor<Recording>())) ?? []).map(\.fileName)
    }

    @Test func m4aBecomesANewMeetingTitledFromTheFileName() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let source = try AudioFixtures.m4aTone(seconds: 1.5, at: FileManager.default.temporaryDirectory
            .appendingPathComponent("Weekly sync \(UUID().uuidString.prefix(4)).m4a"))
        defer { try? FileManager.default.removeItem(at: source) }

        let imported = try await MeetingAudioImporter(context: context, language: .chinese, coachUserName: nil)
            .importAudio(from: source)
        defer { recordingFiles(of: context).forEach(AudioFileStore.delete(fileName:)) }

        #expect(imported.meeting.title == source.deletingPathExtension().lastPathComponent)
        #expect(!imported.isCoach)
        #expect(imported.meeting.coachRecords.isEmpty)
        let recording = try #require(imported.meeting.recordings.first)
        #expect(imported.meeting.recordings.count == 1)
        #expect(recording.id == imported.recordingID)
        #expect(recording.isReadyForConsumption)
        #expect(recording.duration > 1.0)
        #expect(recording.fileName == AudioFileStore.fileName(meetingID: imported.meeting.id, recordingID: recording.id))
        #expect(FileManager.default.fileExists(atPath: AudioFileStore.recordingsDirectoryURL
            .appendingPathComponent(recording.fileName).path))
        // The source belongs to the caller (the inbox deletes its own copies).
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func coachImportGetsACoachRecordSoTheFollowUpTakesTheCoachRoute() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let source = try AudioFixtures.m4aTone(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: source) }

        let imported = try await MeetingAudioImporter(context: context, language: .chinese, coachUserName: "測試者")
            .importAudio(from: source)
        defer { recordingFiles(of: context).forEach(AudioFileStore.delete(fileName:)) }

        #expect(imported.isCoach)
        let recording = try #require(imported.meeting.recordings.first)
        #expect(MeetingCoachFollowUp.isCoachRecording(recording, in: imported.meeting))
        #expect(imported.meeting.coachRecords.first?.userName == "測試者")
        #expect(imported.meeting.coachRecords.first?.ledgers.isEmpty == true)
    }

    @Test func wavIsReencodedToM4A() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let source = try AudioFixtures.wav(segments: [(hz: 440, seconds: 1.5)])
        defer { try? FileManager.default.removeItem(at: source) }

        let imported = try await MeetingAudioImporter(context: context, language: .chinese, coachUserName: nil)
            .importAudio(from: source)
        defer { recordingFiles(of: context).forEach(AudioFileStore.delete(fileName:)) }

        let recording = try #require(imported.meeting.recordings.first)
        #expect(recording.fileName.hasSuffix(".m4a"))
        #expect(recording.duration > 1.0)
    }

    @Test func unreadableAudioLeavesNoMeeting() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let source = try AudioFixtures.undecodableM4A(at: AudioFixtures.tempURL(ext: "m4a"))
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: AppError.self) {
            _ = try await MeetingAudioImporter(context: context, language: .chinese, coachUserName: nil)
                .importAudio(from: source)
        }

        // Decoding fails before a meeting or a stored file exists. Diffing the shared
        // recordings directory here was flaky: other suites write to it concurrently.
        #expect(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
    }

    @Test func acceptsLocalAudioOnly() {
        #expect(MeetingAudioImporter.accepts(URL(fileURLWithPath: "/tmp/memo.m4a")))
        #expect(MeetingAudioImporter.accepts(URL(fileURLWithPath: "/tmp/song.MP3")))
        #expect(MeetingAudioImporter.accepts(URL(fileURLWithPath: "/tmp/take.wav")))
        #expect(!MeetingAudioImporter.accepts(URL(fileURLWithPath: "/tmp/agenda.pdf")))
        #expect(!MeetingAudioImporter.accepts(URL(string: "https://example.com/memo.m4a")!))
    }
}
