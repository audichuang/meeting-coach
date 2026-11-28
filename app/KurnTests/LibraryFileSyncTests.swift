//
//  LibraryFileSyncTests.swift
//  KurnTests
//
//  The reconciliation behind iCloud file sync, against an in-memory remote.
//

import Foundation
import Testing
@testable import Kurn

private actor FakeLibraryFileRemote: LibraryFileRemote {
    private(set) var stored: [String: Data] = [:]
    private(set) var deleted: [String] = []

    func seed(_ fileName: String, _ data: Data) { stored[fileName] = data }

    func upload(fileName: String, from url: URL) async throws {
        stored[fileName] = try Data(contentsOf: url)
    }

    func download(fileName: String) async throws -> URL? {
        guard let data = stored[fileName] else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    func delete(fileNames: [String]) async -> Set<String> {
        deleted += fileNames
        for name in fileNames { stored[name] = nil }
        return Set(fileNames)
    }
}

// Nested so `RecordingsDirectorySuite`'s `.serialized` covers it: it writes
// into the real recordings directory.
extension RecordingsDirectorySuite {
@MainActor
struct LibraryFileSyncTests {
    private let defaults = UserDefaults(suiteName: "LibraryFileSyncTests-\(UUID().uuidString)")!

    private func writeRecording(_ fileName: String, _ bytes: String) throws -> URL {
        let url = try AudioFileStore.ensureRecordingsDirectory().appendingPathComponent(fileName)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @Test func uploadsFinishedFilesButNotACaptureStillWriting() async throws {
        let done = "\(UUID().uuidString)_1.m4a"
        let live = "\(UUID().uuidString)_2.m4a"
        _ = try writeRecording(done, "done")
        _ = try writeRecording(live, "live")
        defer { AudioFileStore.delete(fileName: done); AudioFileStore.delete(fileName: live) }
        let remote = FakeLibraryFileRemote()
        let sync = LibraryFileSync(remote: remote, defaults: defaults)

        await sync.reconcile([
            .init(kind: .recording, fileName: done, isReady: true),
            .init(kind: .recording, fileName: live, isReady: false)
        ])

        #expect(await remote.stored.keys.sorted() == [done])
        #expect(LibraryFileSync.syncedFiles(in: defaults) == [done])
    }

    @Test func downloadsAFileThisDeviceIsMissing() async throws {
        let name = "\(UUID().uuidString)_3.m4a"
        defer { AudioFileStore.delete(fileName: name) }
        let remote = FakeLibraryFileRemote()
        await remote.seed(name, Data("from the iPhone".utf8))
        let sync = LibraryFileSync(remote: remote, defaults: defaults)

        await sync.reconcile([.init(kind: .recording, fileName: name, isReady: true)])

        let local = AudioFileStore.resolveURL(fileName: name)
        #expect(try String(contentsOf: local, encoding: .utf8) == "from the iPhone")
        #expect(LibraryFileSync.syncedFiles(in: defaults) == [name])
    }

    @Test func waitsForAFileNoDeviceHasUploadedYet() async throws {
        let name = "\(UUID().uuidString)_4.m4a"
        let sync = LibraryFileSync(remote: FakeLibraryFileRemote(), defaults: defaults)

        await sync.reconcile([.init(kind: .recording, fileName: name, isReady: true)])

        #expect(!FileManager.default.fileExists(atPath: AudioFileStore.resolveURL(fileName: name).path))
        #expect(LibraryFileSync.syncedFiles(in: defaults).isEmpty)
    }

    @Test func deletesASyncedFileWhoseRowIsGone() async throws {
        let name = "\(UUID().uuidString)_5.m4a"
        let url = try writeRecording(name, "old")
        defer { AudioFileStore.delete(fileName: name) }
        let remote = FakeLibraryFileRemote()
        let sync = LibraryFileSync(remote: remote, defaults: defaults)
        await sync.reconcile([.init(kind: .recording, fileName: name, isReady: true)])

        await sync.reconcile([])

        #expect(await remote.deleted == [name])
        #expect(await remote.stored.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(LibraryFileSync.syncedFiles(in: defaults).isEmpty)
    }

    @Test func forgettingSyncedFilesKeepsEverything() async throws {
        let name = "\(UUID().uuidString)_6.m4a"
        let url = try writeRecording(name, "keep")
        defer { AudioFileStore.delete(fileName: name) }
        let remote = FakeLibraryFileRemote()
        let sync = LibraryFileSync(remote: remote, defaults: defaults)
        await sync.reconcile([.init(kind: .recording, fileName: name, isReady: true)])

        LibraryFileSync.forgetSyncedFiles(in: defaults)
        await sync.reconcile([])

        #expect(await remote.deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aPassReadsTheStore() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Store")
        context.insert(meeting)
        let name = "\(UUID().uuidString)_7.m4a"
        _ = try writeRecording(name, "stored")
        defer { AudioFileStore.delete(fileName: name) }
        context.insert(Recording(meeting: meeting, fileName: name, duration: 1))
        try context.save()
        let remote = FakeLibraryFileRemote()

        await LibraryFileSync(remote: remote, defaults: defaults).sync(context: context)

        #expect(await remote.stored.keys.sorted() == [name])
    }

    @Test func listsTheFilesBehindEveryRow() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Files")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "r.m4a", duration: 1, captureState: .recording)
        context.insert(recording)
        context.insert(MeetingPhoto(recording: recording, fileName: "p.jpg", capturedAt: 1))
        context.insert(MeetingAttachment(meeting: meeting, fileName: "a.pdf", displayName: "A", pageCount: 1))
        try context.save()

        let items = try LibraryFileSync.items(in: context)

        #expect(items.count == 3)
        #expect(items.contains(.init(kind: .recording, fileName: "r.m4a", isReady: false)))
        #expect(items.contains(.init(kind: .photo, fileName: "p.jpg", isReady: true)))
        #expect(items.contains(.init(kind: .attachment, fileName: "a.pdf", isReady: true)))
    }
}
}
