//
//  RecordingRecoveryTests.swift
//  KurnTests
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

// Nested so `RecordingsDirectorySuite`'s `.serialized` covers it.
extension RecordingsDirectorySuite {
@MainActor
struct RecordingRecoveryTests {

    /// With iCloud sync on, a file whose row vanished since the last sweep was
    /// deleted on another device; re-adopting it would undo that delete.
    @Test func removesAFileWhoseRowWasDeletedOnAnotherDevice() throws {
        let defaults = try #require(UserDefaults(suiteName: "RecordingRecoveryTests-\(UUID().uuidString)"))
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Synced")
        context.insert(meeting)
        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = try Self.makeToneFile(named: fileName, seconds: 1.0)
        defer { AudioFileStore.delete(fileName: fileName) }
        let recording = Recording(meeting: meeting, fileName: fileName, duration: 1)
        context.insert(recording)
        try context.save()

        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container, syncEnabled: true, defaults: defaults)
        #expect(FileManager.default.fileExists(atPath: url.path))

        context.delete(recording) // what an imported deletion does to the row
        try context.save()
        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container, syncEnabled: true, defaults: defaults)

        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A restored or fresh store loses rows nobody deleted; its files must be
    /// re-adopted, not removed.
    @Test func forgettingTheSeenListReattachesInsteadOfRemoving() throws {
        let defaults = try #require(UserDefaults(suiteName: "RecordingRecoveryTests-\(UUID().uuidString)"))
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Restored")
        context.insert(meeting)
        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        _ = try Self.makeToneFile(named: fileName, seconds: 1.0)
        defer { AudioFileStore.delete(fileName: fileName) }
        let recording = Recording(meeting: meeting, fileName: fileName, duration: 1)
        context.insert(recording)
        try context.save()
        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container, syncEnabled: true, defaults: defaults)

        context.delete(recording)
        try context.save()
        LibrarySync.forgetSeenRecordingFiles(in: defaults)
        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container, syncEnabled: true, defaults: defaults)

        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.fileName) == [fileName])
    }

    /// Another device's live capture arrives through iCloud without its file;
    /// only that device can tell it from an interrupted one.
    @Test func leavesAnotherDevicesLiveCaptureAlone() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "On the iPhone")
        context.insert(meeting)
        let recording = Recording(
            meeting: meeting, fileName: AudioFileStore.fileName(meetingID: meeting.id),
            duration: 0, captureState: .recording
        )
        recording.originDeviceID = "another-device"
        context.insert(recording)
        try context.save()

        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container)

        #expect(recording.captureState == .recording)
        #expect(recording.captureRecoveryReason == nil)
    }

    @Test func reattachesOrphanedFileToItsMeeting() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        try context.save()

        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = try Self.makeToneFile(named: fileName, seconds: 1.0)
        defer { AudioFileStore.delete(fileName: fileName) }

        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.count == 1)
        #expect(recordings.first?.fileName == fileName)
        #expect(recordings.first?.meeting?.id == meeting.id)
        #expect((recordings.first?.duration ?? 0) > 0.5)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func quarantinesOrphanedFileWithNoMatchingMeeting() throws {
        let container = TestModelContainer.make()

        let fileName = AudioFileStore.fileName(meetingID: UUID())
        _ = try Self.makeToneFile(named: fileName, seconds: 1.0)
        defer {
            for item in RecordingQuarantine.items() where item.fileName == fileName {
                RecordingQuarantine.delete(item)
            }
        }

        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container)

        let recordings = try container.mainContext.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName).path))
        #expect(!FileManager.default.fileExists(atPath: AudioFileStore.documentsURL.appendingPathComponent(fileName).path))
        let item = try #require(RecordingQuarantine.items().first { $0.fileName == fileName })
        #expect(item.reason == .meetingNotFound)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
    }

    @Test func leavesAlreadyKnownFilesUntouched() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)

        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = try Self.makeToneFile(named: fileName, seconds: 1.0)
        defer { AudioFileStore.delete(fileName: fileName) }

        let existing = Recording(meeting: meeting, fileName: fileName, duration: 1.0)
        context.insert(existing)
        try context.save()

        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func finalizingRowWithValidFileConvergesToReady() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Finalizing")
        context.insert(meeting)
        let recordingID = UUID()
        let fileName = AudioFileStore.fileName(meetingID: meeting.id, recordingID: recordingID)
        let url = try Self.makeToneFile(named: fileName, seconds: 1)
        defer { AudioFileStore.delete(fileName: fileName) }
        let recording = Recording(
            id: recordingID,
            meeting: meeting,
            fileName: fileName,
            duration: 0,
            captureState: .finalizing
        )
        context.insert(recording)
        try context.save()

        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container)

        #expect(recording.captureState == .ready)
        #expect(recording.captureRecoveryReason == nil)
        #expect(recording.duration > 0.9)
        #expect(recording.fileSize > 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func recordingRowWithValidPartialFileNeedsRecovery() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Interrupted")
        context.insert(meeting)
        let recordingID = UUID()
        let fileName = AudioFileStore.fileName(meetingID: meeting.id, recordingID: recordingID)
        _ = try Self.makeToneFile(named: fileName, seconds: 1)
        defer { AudioFileStore.delete(fileName: fileName) }
        let recording = Recording(
            id: recordingID,
            meeting: meeting,
            fileName: fileName,
            duration: 0,
            captureState: .recording
        )
        context.insert(recording)
        try context.save()

        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container)

        #expect(recording.captureState == .recoveryNeeded)
        #expect(recording.captureRecoveryReason == .interruptedDuringCapture)
        #expect(recording.duration > 0.9)
        #expect(recording.fileSize > 0)
    }

    @Test func explicitRetryAcceptsAValidatedPartialFile() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Retry")
        context.insert(meeting)
        let recordingID = UUID()
        let fileName = AudioFileStore.fileName(meetingID: meeting.id, recordingID: recordingID)
        _ = try Self.makeToneFile(named: fileName, seconds: 1)
        defer { AudioFileStore.delete(fileName: fileName) }
        let recording = Recording(
            id: recordingID,
            meeting: meeting,
            fileName: fileName,
            duration: 0,
            captureState: .recoveryNeeded,
            captureRecoveryReason: .interruptedDuringCapture
        )
        context.insert(recording)
        try context.save()

        let error = await RecordingRecovery.retryRecovery(for: recording, context: context)

        #expect(error == nil)
        #expect(recording.captureState == .ready)
        #expect(recording.captureRecoveryReason == nil)
        #expect(recording.duration > 0.9)
    }

    @Test func preparingRowWithoutFileRemainsExplicitlyRecoverable() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Preparing")
        context.insert(meeting)
        let recording = Recording(
            meeting: meeting,
            fileName: "missing-\(UUID().uuidString).m4a",
            duration: 0,
            captureState: .preparing
        )
        context.insert(recording)
        try context.save()

        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container)

        #expect(recording.captureState == .recoveryNeeded)
        #expect(recording.captureRecoveryReason == .fileMissing)
    }

    /// Write a short 440 Hz tone directly into the protected recordings
    /// directory under `named`, mirroring how `AudioRecorderService` writes
    /// recordings in production.
    private static func makeToneFile(named fileName: String, seconds: Double) throws -> URL {
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        return try AudioFixtures.m4aTone(seconds: seconds, at: url)
    }
}
}
