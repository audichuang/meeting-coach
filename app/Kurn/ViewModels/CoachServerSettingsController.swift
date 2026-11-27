//
//  CoachServerSettingsController.swift
//  Kurn
//
//  Owns the editable drafts and usage-loading lifecycle for the meeting
//  coach's server URL and invite code in Recording Settings.
//

import Foundation
import KurnCore
import Observation

/// The Settings row for the Worker's `GET /v1/usage`.
enum CoachUsageStatus: Equatable, Sendable {
    case unknown
    case loaded(CoachBackend.Usage)
    case unauthorized
    case failed

    static func load(
        backend: @Sendable () -> CoachBackend? = { CoachBackend.current() },
        fetch: @Sendable (CoachBackend) async throws -> CoachBackend.Usage = { try await $0.usage() }
    ) async -> CoachUsageStatus {
        guard let resolved = backend(), resolved.viaWorker else { return .unknown }
        do {
            return .loaded(try await fetch(resolved))
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

@MainActor
@Observable
final class CoachServerSettingsController {
    var serverURLDraft = ""
    var inviteDraft = ""
    private(set) var usage: CoachUsageStatus = .unknown
    @ObservationIgnored private(set) var committedServerURL = ""
    @ObservationIgnored private(set) var committedInvite = ""
    @ObservationIgnored private(set) var usageTask: Task<Void, Never>?
    @ObservationIgnored private let resolveBackend: @Sendable (String, String) -> CoachBackend?
    @ObservationIgnored private let loadUsage: @Sendable (CoachBackend) async -> CoachUsageStatus

    init(
        resolveBackend: @escaping @Sendable (String, String) -> CoachBackend? = { serverURL, invite in
            CoachBackend.workerBackend(serverURL: serverURL, invite: invite)
        },
        loadUsage: @escaping @Sendable (CoachBackend) async -> CoachUsageStatus = { backend in
            await CoachUsageStatus.load(backend: { backend })
        }
    ) {
        self.resolveBackend = resolveBackend
        self.loadUsage = loadUsage
    }

    var hasUncommittedServerURL: Bool {
        serverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines) != committedServerURL
    }

    func load(settings: AppSettings) {
        committedServerURL = settings.coachServerURL
        serverURLDraft = settings.coachServerURL
        if case .found(let value) = settings.credentials.readKey(for: .meetingCoach) {
            inviteDraft = value
            committedInvite = value
        } else {
            inviteDraft = ""
            committedInvite = ""
        }
        refreshUsage()
    }

    func editServerURL(_ text: String) {
        serverURLDraft = text
        if hasUncommittedServerURL {
            usageTask?.cancel()
            usageTask = nil
        }
    }

    func commitServerURL(settings: AppSettings, forceReload: Bool = false) {
        let next = serverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = next != committedServerURL
        serverURLDraft = next
        committedServerURL = next
        if settings.coachServerURL != next {
            settings.coachServerURL = next
        }
        if changed || forceReload {
            refreshUsage()
        }
    }

    func editInvite(_ text: String) {
        inviteDraft = text
        if text.trimmingCharacters(in: .whitespacesAndNewlines) != committedInvite {
            usageTask?.cancel()
            usageTask = nil
        }
    }

    func commitInvite(settings: AppSettings, forceReload: Bool = false) {
        let next = inviteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = next != committedInvite
        inviteDraft = next
        committedInvite = next
        if changed {
            settings.credentials.saveKey(next, for: .meetingCoach)
        }
        guard !hasUncommittedServerURL else { return }
        if changed || forceReload {
            refreshUsage()
        }
    }

    func disappear(settings: AppSettings) {
        usageTask?.cancel()
        usageTask = nil
        let nextInvite = inviteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if nextInvite != committedInvite {
            inviteDraft = nextInvite
            committedInvite = nextInvite
            settings.credentials.saveKey(nextInvite, for: .meetingCoach)
        }
    }

    private func refreshUsage() {
        usageTask?.cancel()
        usageTask = nil
        guard !hasUncommittedServerURL else { return }
        guard let backend = resolveBackend(committedServerURL, committedInvite), backend.viaWorker else {
            usage = .unknown
            return
        }
        let loadUsage = self.loadUsage
        usageTask = Task { [weak self] in
            let status = await loadUsage(backend)
            guard let self, !Task.isCancelled else { return }
            self.usage = status
        }
    }
}
