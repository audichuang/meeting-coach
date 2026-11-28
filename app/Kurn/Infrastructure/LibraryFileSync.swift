//
//  LibraryFileSync.swift
//  Kurn
//
//  Moves the files behind synced rows — recordings, photos, attachments —
//  between devices when `LibrarySync` is on. SwiftData mirrors only the
//  store, so a recording made on the iPhone would otherwise reach the iPad as
//  a row with no audio. Each file is one remote record keyed by its file name
//  (`CloudKitLibraryFileRemote`); the files never go into the store, which
//  would hold a second copy of every recording on each device.
//
//  A pass reconciles against `syncedFiles`, the names this device has already
//  uploaded or downloaded: a device that has a file nobody has synced yet
//  uploads it, a device missing one downloads it, and a synced name whose
//  row is gone was deleted (here or on another device), so its remote record
//  and local copy go too. Many views build their own `MeetingLibrary`, so
//  deletes are found by this reconciliation rather than by a delete hook.
//

import Foundation
import KurnCore
import SwiftData

/// The remote half, injected so the reconciliation is testable without iCloud.
protocol LibraryFileRemote: Sendable {
    func upload(fileName: String, from url: URL) async throws
    /// A local copy of the remote file, or nil when no device has uploaded it yet.
    func download(fileName: String) async throws -> URL?
    /// Returns the names that are no longer on the remote (deleted now or already gone).
    func delete(fileNames: [String]) async -> Set<String>
}

@MainActor
final class LibraryFileSync {
    enum Kind: CaseIterable, Sendable {
        case recording, photo, attachment

        func localURL(fileName: String) -> URL {
            switch self {
            case .recording: AudioFileStore.resolveURL(fileName: fileName)
            case .photo: PhotoFileStore.resolveURL(fileName: fileName)
            case .attachment: AttachmentFileStore.resolveURL(fileName: fileName)
            }
        }

        func ensureDirectory() throws -> URL {
            switch self {
            case .recording: try AudioFileStore.ensureRecordingsDirectory()
            case .photo: try PhotoFileStore.ensurePhotosDirectory()
            case .attachment: try AttachmentFileStore.ensureAttachmentsDirectory()
            }
        }
    }

    struct Item: Equatable, Sendable {
        let kind: Kind
        let fileName: String
        /// False while a capture is still writing the file: never upload half a recording.
        let isReady: Bool
    }

    static let syncedFilesKey = "librarySync.syncedFiles"

    private let remote: any LibraryFileRemote
    private let defaults: UserDefaults
    private var isRunning = false
    private var needsRerun = false

    init(remote: any LibraryFileRemote, defaults: UserDefaults = .standard) {
        self.remote = remote
        self.defaults = defaults
    }

    /// Every file a row in `context` refers to. Throws rather than returning an
    /// empty list when the store cannot be read: an empty list would read as
    /// "everything was deleted" and remove every synced file.
    static func items(in context: ModelContext) throws -> [Item] {
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        let photos = try context.fetch(FetchDescriptor<MeetingPhoto>())
        let attachments = try context.fetch(FetchDescriptor<MeetingAttachment>())
        return recordings.map { Item(kind: .recording, fileName: $0.fileName, isReady: $0.captureState == .ready) }
            + photos.map { Item(kind: .photo, fileName: $0.fileName, isReady: true) }
            + attachments.map { Item(kind: .attachment, fileName: $0.fileName, isReady: true) }
    }

    /// Runs one pass over the store; a request while a pass is running queues
    /// one more pass, so rows imported mid-pass are not left waiting for the
    /// next activation.
    func sync(context: ModelContext) async {
        guard !isRunning else {
            needsRerun = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            needsRerun = false
            guard let items = try? Self.items(in: context) else { return }
            await reconcile(items)
        } while needsRerun
    }

    func reconcile(_ items: [Item]) async {
        var synced = Self.syncedFiles(in: defaults)
        let live = Set(items.map(\.fileName))
        let gone = synced.subtracting(live)
        if !gone.isEmpty {
            let removed = await remote.delete(fileNames: gone.sorted())
            for name in gone {
                AudioFileStore.delete(fileName: name) // also drops its enhanced copy and capture journal
                try? FileManager.default.removeItem(at: Kind.photo.localURL(fileName: name))
                try? FileManager.default.removeItem(at: Kind.attachment.localURL(fileName: name))
            }
            synced.subtract(removed)
            Self.save(synced, in: defaults)
        }
        for item in items where !synced.contains(item.fileName) {
            do {
                if try await transfer(item) {
                    synced.insert(item.fileName)
                    Self.save(synced, in: defaults)
                }
            } catch {
                AppLog.persistence.atError.error(
                    "file sync: \(item.fileName, privacy: .public) failed code=\(error.publicLogCode, privacy: .public)"
                )
            }
        }
    }

    /// - Returns: whether the file is now on both sides.
    private func transfer(_ item: Item) async throws -> Bool {
        let local = item.kind.localURL(fileName: item.fileName)
        if FileManager.default.fileExists(atPath: local.path) {
            guard item.isReady else { return false }
            try await remote.upload(fileName: item.fileName, from: local)
            return true
        }
        guard let downloaded = try await remote.download(fileName: item.fileName) else { return false }
        let destination = try item.kind.ensureDirectory().appendingPathComponent(item.fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: downloaded, to: destination)
        RecordingProtection.apply(to: destination)
        return true
    }

    // MARK: - Persisted state

    static func syncedFiles(in defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: syncedFilesKey) ?? [])
    }

    private static func save(_ names: Set<String>, in defaults: UserDefaults) {
        defaults.set(names.sorted(), forKey: syncedFilesKey)
    }

    /// A restored or fresh store loses rows nobody deleted; without this the
    /// next pass would delete every synced file locally and in iCloud.
    static func forgetSyncedFiles(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: syncedFilesKey)
    }
}
