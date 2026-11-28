//
//  LibrarySyncSettingsView.swift
//  Kurn
//
//  The opt-in for iCloud library sync (`LibrarySync`). The store picks the
//  setting up when it opens, so the screen says when a change is still
//  waiting for the next launch.
//

import SwiftUI

struct LibrarySyncSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(
                    NSLocalizedString("settings.library_sync", comment: "Sync meetings via iCloud"),
                    isOn: $settings.librarySyncEnabled
                )
                .accessibilityIdentifier("settings.librarySync.toggle")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("settings.library_sync_footer", comment: "What library sync does"))
                    if settings.librarySyncEnabled != LibrarySync.enabledAtLaunch {
                        Text(NSLocalizedString("settings.library_sync_restart", comment: "Applies after reopening the app"))
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.library_sync_title", comment: "iCloud Sync"))
    }
}
