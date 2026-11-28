//
//  ContentView.swift
//  Kurn
//
//  Root navigation. On compact width (iPhone, or iPad in a narrow Split View)
//  a single NavigationStack hosts the meetings list and the app's other
//  sections, with the folder/library picker reached through a sheet
//  (`FolderSidebarView`, opened from the toolbar). On regular width (iPad,
//  Mac Catalyst) a NavigationSplitView instead shows that same picker as a
//  sidebar column next to the meetings list (collapsed at launch, opened
//  from the system sidebar button): the app is declared
//  universal, and a full-screen sheet wasted the width iPad has. `selection` moved up to this
//  view specifically so the same `Binding<LibrarySelection>` can drive both
//  `FolderSidebarView` (sidebar or sheet) and `MeetingsListView`'s own
//  filtering without a sheet round-trip on regular width. Settings is
//  presented as a sheet either way. The recorder and its minimized mini bar
//  are attached here (`recordingSessionPresenter()`), above both layouts, so
//  a recording stays reachable from every screen. A PDF shared into the app
//  from another one is offered here too (`AttachToMeetingView`), above both
//  layouts, for the user to pick the meeting it belongs to. The App Store
//  rating prompt (`reviewPromptPresenter()`) is attached at the same level,
//  so it can follow a finished transcript or summary on any screen. A fresh
//  install that is not signed in to the meeting coach first sees
//  `CoachSignInPromptView`, once.
//

import KurnCore
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(IncomingFileInbox.self) private var incomingFiles
    @Environment(AppSettings.self) private var settings
    @Environment(TranscriptionCoordinator.self) private var transcription
    @State private var selection: LibrarySelection = .allMeetings
    /// iPad opens on the meetings list; the library column is one tap away
    /// on the system sidebar button instead of greeting a new user with a
    /// column of zero counts.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var isImportingAudio = false
    @State private var audioImportError: AppError?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $sidebarVisibility) {
                    FolderSidebarView(selection: $selection, showsDoneButton: false)
                } detail: {
                    NavigationStack {
                        MeetingsListView(selection: $selection)
                    }
                }
            } else {
                NavigationStack {
                    MeetingsListView(selection: $selection)
                }
            }
        }
        .recordingSessionPresenter()
        .reviewPromptPresenter()
        .sheet(isPresented: Binding(
            get: { incomingFiles.hasPendingFiles },
            set: { if !$0 { incomingFiles.finish() } }
        )) {
            AttachToMeetingView(files: incomingFiles.pendingFiles, modelContext: modelContext) {
                incomingFiles.finish()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { CoachSignInPromptView.isNeeded(settings: settings) },
            set: { if !$0 { settings.coachSignInPromptShown = true } }
        )) {
            CoachSignInPromptView()
        }
        .onChange(of: incomingFiles.pendingAudio, initial: true) { importNextAudio() }
        .errorAlert($audioImportError)
    }

    /// Imports queued audio one file at a time (shared from Voice Memos or
    /// picked in the library), then starts the coach follow-up when the
    /// import took the coach route.
    private func importNextAudio() {
        guard !isImportingAudio, let url = incomingFiles.pendingAudio.first else { return }
        isImportingAudio = true
        let importer = MeetingAudioImporter(
            context: modelContext,
            language: settings.defaultLanguage,
            coachUserName: MeetingAudioImporter.coachUserName(settings: settings)
        )
        Task {
            do throws(AppError) {
                let imported = try await importer.importAudio(from: url)
                if imported.isCoach {
                    MeetingCoachFollowUp(transcription: transcription, settings: settings)
                        .start(meeting: imported.meeting, recordingID: imported.recordingID)
                }
            } catch {
                audioImportError = error
            }
            isImportingAudio = false
            incomingFiles.finishAudio(url)
        }
    }
}

#Preview {
    // `ContentView` renders `MeetingsListView`; only `MeetingDetailView` (reached
    // via navigation) reads `SummaryViewModel`, so this preview doesn't inject it.
    @Previewable @State var settings = AppSettings()
    let container = try? ModelContainer(
        for: Meeting.self, Recording.self, Transcript.self, Speaker.self, Summary.self,
        Folder.self, Tag.self, SmartFolder.self, GeneratedDocument.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
    if let container {
        ContentView()
            .environment(settings)
            .environment(RecordingAccessGate())
            .environment(IncomingFileInbox())
            .environment(TranscriptionCoordinator(modelContext: container.mainContext, appSettings: settings))
            .environment(RecordingSessionController(modelContext: container.mainContext, settings: settings))
            .environment(ReviewPromptCoordinator())
            .environment(MeetingChatStore(modelContext: container.mainContext))
            .modelContainer(container)
    }
}
