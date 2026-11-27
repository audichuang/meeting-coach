//
//  IncomingFileInbox.swift
//  Kurn
//
//  Holds files another app shared into Kurn. The app declares PDF and audio
//  as document types it can open (`CFBundleDocumentTypes` in `Info.plist`,
//  not in place), so Kurn appears in the share sheet of Files, Mail, Safari,
//  Voice Memos and every other app showing one; iOS then copies the file into
//  `Documents/Inbox/` and hands its URL to `onOpenURL`, which lands here.
//  PDFs wait for the user to pick a meeting (`ContentView` presents
//  `AttachToMeetingView`); audio waits for `ContentView` to import it as a
//  new meeting (`MeetingAudioImporter`), since the store may not be open yet
//  when the URL arrives. The in-app audio importer queues its picks here too.
//
//  The Inbox copy is outside the protected recordings directory, so it must
//  not outlive the decision: attaching copies it into `AttachmentFileStore`
//  and `finish()` deletes it; cancelling deletes it too. Only files inside
//  the Inbox are ever deleted — a URL pointing anywhere else (a file opened
//  in place by a future configuration) is the user's own and is left alone.
//  `sweepStaleCopies` removes what a process killed mid-decision left behind.
//
//  Nothing here reads meeting content, and the picker it drives is presented
//  below `SecurityCoverWindow`, so a share arriving while the app is locked
//  waits behind the lock like everything else.
//

import Foundation
import Observation

@MainActor
@Observable
final class IncomingFileInbox {
    /// PDFs waiting for a meeting, in arrival order.
    private(set) var pendingFiles: [URL] = []
    /// Audio files waiting to become meetings, in arrival order.
    private(set) var pendingAudio: [URL] = []

    @ObservationIgnored private let inboxDirectory: URL
    @ObservationIgnored private let fileManager: FileManager

    init(
        inboxDirectory: URL = AudioFileStore.documentsURL.appendingPathComponent("Inbox", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.inboxDirectory = inboxDirectory
        self.fileManager = fileManager
    }

    var hasPendingFiles: Bool { !pendingFiles.isEmpty }

    /// Accepts a URL handed to the app. Only local PDF and audio files are
    /// queued; anything else (a web link, another file type) is ignored and
    /// reported as such.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        if MeetingAudioImporter.accepts(url) {
            if !pendingAudio.contains(url) { pendingAudio.append(url) }
            return true
        }
        guard Self.accepts(url) else { return false }
        if !pendingFiles.contains(url) {
            pendingFiles.append(url)
        }
        return true
    }

    /// One audio file has been imported (or its failure reported): deletes its
    /// Inbox copy and drops it from the queue.
    func finishAudio(_ url: URL) {
        discardInboxCopy(at: url)
        pendingAudio.removeAll { $0 == url }
    }

    /// The files have been dealt with (attached, or a failure reported):
    /// deletes the Inbox copies and empties the queue.
    func finish() {
        for url in pendingFiles {
            discardInboxCopy(at: url)
        }
        pendingFiles.removeAll()
    }

    /// Removes Inbox copies older than `maxAge` that nothing is waiting on —
    /// left behind when the process ended before the user chose a meeting.
    func sweepStaleCopies(maxAge: TimeInterval = 24 * 60 * 60, now: Date = Date()) {
        guard let items = try? fileManager.contentsOfDirectory(
            at: inboxDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let pending = Set((pendingFiles + pendingAudio).map(\.standardizedFileURL))
        for url in items where !pending.contains(url.standardizedFileURL) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) < maxAge { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Whether `url` is something the inbox takes: a local file with a PDF
    /// extension.
    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "pdf"
    }

    /// Deletes `url` when — and only when — it is a copy iOS placed in the
    /// app's Inbox.
    func discardInboxCopy(at url: URL) {
        let inboxPath = inboxDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(inboxPath + "/") else { return }
        try? fileManager.removeItem(at: url)
    }
}
