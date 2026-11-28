//
//  CoachServerSettingsController.swift
//  Kurn
//
//  Owns the usage-loading lifecycle and sign-out for the meeting coach's
//  account row in Recording Settings. Signing in is `CoachSignInButton`; the
//  Worker address is fixed at build time.
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
        case .unauthorized: return NSLocalizedString("settings.meeting_coach_session_invalid", comment: "Sign-in no longer valid")
        case .notConfigured: return NSLocalizedString("coach.error.accessMissing", comment: "Build lacks the Worker address or Access token")
        case .failed: return NSLocalizedString("settings.meeting_coach_usage_failed", comment: "Usage could not be loaded")
        }
    }
}

@MainActor
@Observable
final class CoachServerSettingsController {
    private(set) var usage: CoachUsageStatus = .unknown
    /// Keychain read failure surfaced to `RecordingSettingsView`'s `.errorAlert`.
    var error: AppError?
    @ObservationIgnored private(set) var usageTask: Task<Void, Never>?
    @ObservationIgnored private let resolveBackend: @Sendable (String) -> CoachBackend?
    @ObservationIgnored private let loadUsage: @Sendable (CoachBackend) async -> CoachUsageStatus

    init(
        resolveBackend: @escaping @Sendable (String) -> CoachBackend? = { token in
            CoachBackend.workerBackend(invite: token)
        },
        loadUsage: @escaping @Sendable (CoachBackend) async -> CoachUsageStatus = { backend in
            await CoachUsageStatus.load(backend: { backend })
        }
    ) {
        self.resolveBackend = resolveBackend
        self.loadUsage = loadUsage
    }

    /// Reads the stored token and reloads usage; call on appear and after signing in.
    func load(settings: AppSettings) {
        var token = ""
        switch settings.credentials.readKey(for: .meetingCoach) {
        case .found(let value): token = value
        case .absent: break
        case .failed(let reason): error = .keychainAccessFailed(reason.rawValue)
        }
        usageTask?.cancel()
        usageTask = nil
        guard let backend = resolveBackend(token), backend.viaWorker else {
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

    func signOut(settings: AppSettings) {
        CoachSignIn.signOut(settings: settings)
        load(settings: settings)
    }

    func disappear() {
        usageTask?.cancel()
        usageTask = nil
    }
}
