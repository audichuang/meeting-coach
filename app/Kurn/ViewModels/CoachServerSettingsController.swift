//
//  CoachServerSettingsController.swift
//  Kurn
//
//  Owns the editable drafts and usage-loading lifecycle for the meeting
//  coach's invite code in Recording Settings. The Worker address is fixed at build time.
//

import Foundation
import KurnCore
import Observation

/// The Settings row for the Worker's `GET /v1/usage`.
enum CoachUsageStatus: Equatable, Sendable {
    case unknown
    case loaded(CoachBackend.Usage)
    case unauthorized
    case notConfigured
    case failed

    static func load(
        backend: @Sendable () -> CoachBackend? = { CoachBackend.current() },
        fetch: @Sendable (CoachBackend) async throws -> CoachBackend.Usage = { try await $0.usage() }
    ) async -> CoachUsageStatus {
        guard let resolved = backend(), resolved.viaWorker else { return .unknown }
        do {
            return .loaded(try await fetch(resolved))
        } catch {
            if error.isCoachNotConfigured { return .notConfigured }
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
        case .notConfigured: return NSLocalizedString("coach.error.accessMissing", comment: "Build lacks the Worker address or Access token")
        case .failed: return NSLocalizedString("settings.meeting_coach_usage_failed", comment: "Usage could not be loaded")
        }
    }
}

@MainActor
@Observable
final class CoachServerSettingsController {
    var inviteDraft = ""
    private(set) var usage: CoachUsageStatus = .unknown
    /// Keychain read/write failure surfaced to `RecordingSettingsView`'s `.errorAlert`.
    var error: AppError?
    @ObservationIgnored private(set) var committedInvite = ""
    @ObservationIgnored private(set) var usageTask: Task<Void, Never>?
    @ObservationIgnored private let resolveBackend: @Sendable (String) -> CoachBackend?
    @ObservationIgnored private let loadUsage: @Sendable (CoachBackend) async -> CoachUsageStatus

    init(
        resolveBackend: @escaping @Sendable (String) -> CoachBackend? = { invite in
            CoachBackend.workerBackend(invite: invite)
        },
        loadUsage: @escaping @Sendable (CoachBackend) async -> CoachUsageStatus = { backend in
            await CoachUsageStatus.load(backend: { backend })
        }
    ) {
        self.resolveBackend = resolveBackend
        self.loadUsage = loadUsage
    }

    func load(settings: AppSettings) {
        switch settings.credentials.readKey(for: .meetingCoach) {
        case .found(let value):
            inviteDraft = value
            committedInvite = value
        case .absent:
            inviteDraft = ""
            committedInvite = ""
        case .failed(let reason):
            inviteDraft = ""
            committedInvite = ""
            error = .keychainAccessFailed(reason.rawValue)
        }
        refreshUsage()
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
        if changed {
            let outcome = settings.credentials.saveKey(next, for: .meetingCoach)
            guard case .success = outcome else {
                if case .failed(let reason) = outcome {
                    error = .keychainAccessFailed(reason.rawValue)
                }
                return
            }
            committedInvite = next
            error = nil
        }
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
            switch settings.credentials.saveKey(nextInvite, for: .meetingCoach) {
            case .success:
                committedInvite = nextInvite
                error = nil
            case .failed(let reason):
                error = .keychainAccessFailed(reason.rawValue)
            }
        }
    }

    private func refreshUsage() {
        usageTask?.cancel()
        usageTask = nil
        guard let backend = resolveBackend(committedInvite), backend.viaWorker else {
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
