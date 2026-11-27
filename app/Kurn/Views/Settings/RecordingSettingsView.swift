//
//  RecordingSettingsView.swift
//  Kurn
//
//  Capture-time preferences: which microphone and quality to record at, the
//  opt-in live transcript preview, and the two privacy switches that guard
//  recordings on device and on the Lock Screen. Split into named sections
//  (Capture / Live Transcription / Playback / Privacy); where a section has
//  several controls, each one carries its own explanation under its title
//  (`SettingsRowLabel`) instead of a footer paragraph per control.
//

import KurnCore
import SwiftUI

struct RecordingSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadController.self) private var downloads
    /// Pushed from a live-preview model download the large-transfer policy
    /// refused; the switches live on the Transcription screen.
    @State private var showingNetworkSettings = false
    /// Set when turning the recordings lock off was refused by the
    /// re-authentication prompt.
    @State private var authError: AppError?
    private let authorizer = SensitiveActionAuthorizer()
    /// The invite code being edited; written to the Keychain as it changes.
    @State private var inviteDraft = ""
    @State private var coachUsage: CoachUsageStatus = .unknown

    var body: some View {
        Form {
            captureSection
            meetingCoachSection
            liveTranscriptionSection
            playbackSection
            privacySection
        }
        .navigationTitle(NSLocalizedString("settings.recording", comment: "Recording"))
        .modelDownloadAlerts(downloads, settings: settings) { showingNetworkSettings = true }
        .errorAlert($authError)
        .navigationDestination(isPresented: $showingNetworkSettings) {
            TranscriptionSettingsView()
        }
    }

    // MARK: - Capture

    @ViewBuilder
    private var captureSection: some View {
        Section {
            Picker(
                selection: Binding(
                    get: { settings.micPickup },
                    set: { settings.micPickup = $0 }
                )
            ) {
                ForEach(MicPickup.allCases) { Text($0.displayName).tag($0) }
            } label: {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.mic_pickup", comment: "Microphone"),
                    detail: NSLocalizedString("settings.mic_pickup_footer", comment: "Explains pickup modes")
                )
            }
            Picker(
                selection: Binding(
                    get: { settings.audioQuality },
                    set: { settings.audioQuality = $0 }
                )
            ) {
                ForEach(AudioQuality.allCases) { Text($0.displayName).tag($0) }
            } label: {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.audio_quality", comment: "Audio quality"),
                    detail: NSLocalizedString("settings.audio_quality_footer", comment: "Explains that every tier preserves speech")
                )
            }
            LabeledContent(
                NSLocalizedString("settings.audio_quality.usage", comment: "Storage per hour"),
                value: String(
                    format: NSLocalizedString("settings.audio_quality.per_hour", comment: "Size per hour of recording"),
                    AudioFileStore.formattedSize(settings.audioQuality.approximateBytesPerHour)
                )
            )
            Toggle(
                isOn: Binding(
                    get: { settings.alwaysUseBuiltInMic },
                    set: { settings.alwaysUseBuiltInMic = $0 }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.always_use_built_in_mic", comment: "Always use iPhone microphone"),
                    detail: NSLocalizedString("settings.always_use_built_in_mic_footer", comment: "Explains forcing the iPhone mic vs. being asked")
                )
            }
        } header: {
            Text(NSLocalizedString("settings.recording_section_capture", comment: "Capture"))
        }
    }

    // MARK: - Meeting coach

    @ViewBuilder
    private var meetingCoachSection: some View {
        Section {
            Toggle(
                NSLocalizedString("settings.meeting_coach", comment: "Meeting coach"),
                isOn: Binding(get: { settings.meetingCoachEnabled }, set: { settings.meetingCoachEnabled = $0 })
            )
            LabeledContent(NSLocalizedString("settings.meeting_coach_server", comment: "Server URL for the coach")) {
                TextField(
                    "https://",
                    text: Binding(get: { settings.coachServerURL }, set: { settings.coachServerURL = $0 })
                )
                .multilineTextAlignment(.trailing)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(NSLocalizedString("settings.meeting_coach_server", comment: "Server URL for the coach"))
            }
            LabeledContent(NSLocalizedString("settings.meeting_coach_invite", comment: "Invite code for the coach server")) {
                SecureField(NSLocalizedString("settings.meeting_coach_invite", comment: "Invite code for the coach server"), text: $inviteDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: inviteDraft) { _, newValue in settings.credentials.saveKey(newValue, for: .meetingCoach) }
            }
            if let usageText = coachUsage.text {
                LabeledContent(NSLocalizedString("settings.meeting_coach_usage", comment: "This month's coach spend"), value: usageText)
            }
            LabeledContent(NSLocalizedString("settings.meeting_coach_name", comment: "Your name, used by the coach")) {
                TextField(
                    NSLocalizedString("settings.meeting_coach_name", comment: "Your name, used by the coach"),
                    text: Binding(get: { settings.coachUserName }, set: { settings.coachUserName = $0 })
                )
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            Stepper(
                value: Binding(get: { settings.coachBudgetUSD }, set: { settings.coachBudgetUSD = $0 }),
                in: 1...100,
                step: 1
            ) {
                Text(String(format: NSLocalizedString("settings.meeting_coach_budget", comment: "Spend warning threshold"), settings.coachBudgetUSD))
            }
            Stepper(
                value: Binding(get: { settings.coachCooldownSeconds }, set: { settings.coachCooldownSeconds = $0 }),
                in: 30...600,
                step: 30
            ) {
                Text(String(format: NSLocalizedString("settings.meeting_coach_cooldown", comment: "Minimum seconds between automatic cards"),
                            Int(settings.coachCooldownSeconds)))
            }
            Stepper(
                value: Binding(get: { settings.coachMaxCardsPerWindow }, set: { settings.coachMaxCardsPerWindow = $0 }),
                in: 1...10
            ) {
                Text(String(format: NSLocalizedString("settings.meeting_coach_max_cards", comment: "Most automatic cards per 10 minutes"),
                            settings.coachMaxCardsPerWindow))
            }
        } header: {
            Text(NSLocalizedString("settings.meeting_coach", comment: "Meeting coach"))
        } footer: {
            Text(NSLocalizedString("settings.meeting_coach_footer", comment: "Explains the coach sends audio through the server"))
        }
        .onAppear {
            if case .found(let value) = settings.credentials.readKey(for: .meetingCoach) { inviteDraft = value }
        }
        .task(id: "\(settings.coachServerURL)|\(settings.credentials.revision)") {
            // Debounces typing in either field before asking the server.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            coachUsage = await CoachUsageStatus.load()
        }
    }

    // MARK: - Live transcription

    @ViewBuilder
    private var liveTranscriptionSection: some View {
        Section {
            Toggle(
                NSLocalizedString("settings.live_transcription", comment: "Live transcription"),
                isOn: Binding(
                    get: { settings.liveTranscriptionEnabled },
                    set: { downloads.setLiveTranscriptionEnabled($0, settings: settings) }
                )
            )
            .disabled(downloads.isDownloading)
            FluidAudioLiveSettingsControls()
            if FluidAudioModelPresentation.downloadSection(for: downloads.downloadingModel) == .live {
                ModelDownloadProgressRow(progress: downloads.downloadProgress, onCancel: downloads.cancelDownload)
            }
        } header: {
            Text(NSLocalizedString("settings.recording_section_live_transcription", comment: "Live Transcription"))
        } footer: {
            Text(NSLocalizedString("settings.live_transcription_footer", comment: "Explains the live transcription preview"))
        }
    }

    // MARK: - Playback

    // Playback-side, unlike the capture section above. It lives on this screen
    // because it is about listening to recordings, and the per-recording
    // control is the pill in the player.
    @ViewBuilder
    private var playbackSection: some View {
        Section {
            Toggle(
                NSLocalizedString("settings.playback_enhancement", comment: "Enhanced playback"),
                isOn: Binding(
                    get: { settings.playbackEnhancementEnabled },
                    set: { settings.playbackEnhancementEnabled = $0 }
                )
            )
        } header: {
            Text(NSLocalizedString("settings.recording_section_playback", comment: "Playback"))
        } footer: {
            Text(NSLocalizedString("settings.playback_enhancement_footer", comment: "Explains the enhanced playback copy"))
        }
    }

    // MARK: - Privacy

    @ViewBuilder
    private var privacySection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { settings.requireAuthForRecordings },
                    set: { setRequireAuth($0) }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.require_auth_for_recordings", comment: "Require authentication for recordings"),
                    detail: NSLocalizedString("settings.require_auth_for_recordings_footer", comment: "Explains authentication and at-rest encryption")
                )
            }
            Toggle(
                isOn: Binding(
                    get: { settings.hideLiveActivityMeetingTitle },
                    set: { settings.hideLiveActivityMeetingTitle = $0 }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.hide_live_activity_meeting_title", comment: "Hide meeting title on Lock Screen"),
                    detail: NSLocalizedString("settings.hide_live_activity_meeting_title_footer", comment: "Explains Live Activity title redaction")
                )
            }
        } header: {
            Text(NSLocalizedString("settings.recording_section_privacy", comment: "Privacy"))
        } footer: {
            Text(NSLocalizedString("settings.recording_section_privacy_footer", comment: "Explains audio is always encrypted regardless of these toggles"))
        }
    }

    /// Switching the lock off re-authenticates first (`SensitiveActionAuthorizer`):
    /// an unlocked session alone must not be enough to remove the protection.
    /// The toggle keeps reading the stored value, so it snaps back on refusal.
    private func setRequireAuth(_ newValue: Bool) {
        let current = settings.requireAuthForRecordings
        Task { @MainActor in
            switch await authorizer.authorizeRequireAuthChange(to: newValue, currentlyRequired: current) {
            case .authorized: settings.requireAuthForRecordings = newValue
            case .cancelled: break
            case .denied(let error): authError = error
            }
        }
    }
}

/// The Settings row for the Worker's `GET /v1/usage`.
enum CoachUsageStatus: Equatable {
    case unknown
    case loaded(CoachBackend.Usage)
    case unauthorized
    case failed

    static func load() async -> CoachUsageStatus {
        guard let backend = CoachBackend.current(), backend.viaWorker else { return .unknown }
        do {
            return .loaded(try await backend.usage())
        } catch {
            return error.isCoachUnauthorized ? .unauthorized : .failed
        }
    }

    var text: String? {
        switch self {
        case .unknown: return nil
        case .loaded(let usage):
            return String(format: NSLocalizedString("settings.meeting_coach_usage_value", comment: "Spent of cap, USD"),
                          usage.month.usd, usage.monthlyCapUSD)
        case .unauthorized: return NSLocalizedString("settings.meeting_coach_invite_invalid", comment: "Invite code rejected")
        case .failed: return NSLocalizedString("settings.meeting_coach_usage_failed", comment: "Usage could not be loaded")
        }
    }
}
