//
//  LibrarySync.swift
//  Kurn
//
//  Opt-in iCloud mirroring of the library (the SwiftData store through
//  CloudKit's private database; recordings follow in `RecordingAudioSync`).
//  Off by default. The setting is read once, when the store opens: SwiftData
//  cannot switch a live container's mirroring, so a change applies at the
//  next launch. Every other `ModelConfiguration` in the app and its tests
//  passes `cloudKitDatabase: .none` explicitly, because the default
//  (`.automatic`) turns mirroring on whenever the iCloud entitlement exists.
//

import Foundation
import SwiftData

enum LibrarySync {
    static let containerIdentifier = "iCloud.com.audichuang.meetingcoach"
    static let enabledKey = "settings.librarySyncEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The value the store was opened with, fixed for the life of the process.
    static let enabledAtLaunch: Bool = isEnabled()

    static func cloudKitDatabase(enabled: Bool) -> ModelConfiguration.CloudKitDatabase {
        enabled ? .private(containerIdentifier) : .none
    }

    // MARK: - Deletions from another device

    static let seenRecordingFilesKey = "librarySync.seenRecordingFiles"

    /// Recording file names that had a row at the last orphan sweep. A local
    /// delete moves the file to the trash before the row goes, so with sync on
    /// a file here whose row has vanished was deleted on another device, and
    /// recovery must remove it rather than re-adopt it into its meeting.
    static func seenRecordingFiles(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: seenRecordingFilesKey) ?? [])
    }

    static func rememberRecordingFiles(_ fileNames: Set<String>, in defaults: UserDefaults = .standard) {
        defaults.set(fileNames.sorted(), forKey: seenRecordingFilesKey)
    }

    /// A restored or fresh store drops rows without anyone deleting them, so
    /// the last sweep's list no longer means "deleted elsewhere".
    static func forgetSeenRecordingFiles(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: seenRecordingFilesKey)
    }
}
