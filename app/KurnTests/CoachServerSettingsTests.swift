//
//  CoachServerSettingsTests.swift
//  KurnTests
//
//  The meeting coach's invite code and usage row in Recording Settings. The
//  Worker address is fixed at build time, so there is no URL to edit.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
@Suite("CoachServerSettings")
struct CoachServerSettingsTests {

    private final class MemoryKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]
        private var _failWrite: KeychainFailureReason?
        private var _failRead: KeychainFailureReason?
        private var _writeAttempts = 0

        var failWrite: KeychainFailureReason? {
            get { lock.withLock { _failWrite } }
            set { lock.withLock { _failWrite = newValue } }
        }
        var failRead: KeychainFailureReason? {
            get { lock.withLock { _failRead } }
            set { lock.withLock { _failRead = newValue } }
        }
        var writeAttempts: Int { lock.withLock { _writeAttempts } }

        func get(_ account: String) -> KeychainReadOutcome {
            lock.withLock {
                if let reason = _failRead { return .failed(reason) }
                guard let value = storage[account] else { return .absent }
                return .found(value)
            }
        }

        @discardableResult
        func set(_ value: String, for account: String) -> KeychainWriteOutcome {
            lock.withLock {
                _writeAttempts += 1
                if let reason = _failWrite { return .failed(reason) }
                storage[account] = value
                return .success
            }
        }

        @discardableResult
        func delete(_ account: String) -> KeychainWriteOutcome {
            lock.withLock {
                _writeAttempts += 1
                if let reason = _failWrite { return .failed(reason) }
                storage[account] = nil
                return .success
            }
        }
    }

    private func makeSettings(
        initialInvite: String = "",
        keychain: MemoryKeychain = MemoryKeychain()
    ) throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "CoachServerSettingsTests-\(UUID().uuidString)"))
        if !initialInvite.isEmpty {
            keychain.set(initialInvite, for: AIProvider.meetingCoach.keychainAccount)
        }
        let settings = AppSettings(
            cloudStore: InMemoryCloudKeyValueStore(),
            defaults: defaults,
            credentials: CredentialStore(keychain: keychain)
        )
        return settings
    }

    private func makeController(
        recorded: Recorded<CoachBackend>,
        status: CoachUsageStatus = .loaded(CoachBackend.Usage(month: .init(usd: 1.25), monthlyCapUSD: 20))
    ) -> CoachServerSettingsController {
        CoachServerSettingsController(
            resolveBackend: { invite in
                guard !invite.isEmpty else { return nil }
                return CoachBackend(baseURL: URL(string: "https://coach.example.test/v1")!, token: invite, viaWorker: true)
            },
            loadUsage: { backend in
                recorded.append(backend)
                return status
            }
        )
    }

    @Test func coachUsageStatusMapsResponsesAndAuthErrors() async {
        let backend = CoachBackend(baseURL: URL(string: "https://coach.example.test/v1")!, token: "synthetic", viaWorker: true)
        let usage = CoachBackend.Usage(month: .init(usd: 2.5), monthlyCapUSD: 25)

        let loaded = await CoachUsageStatus.load(backend: { backend }, fetch: { _ in usage })
        #expect(loaded == .loaded(usage))
        #expect(loaded.text != nil)

        let unauthorized = await CoachUsageStatus.load(
            backend: { backend },
            fetch: { _ in throw AppError.apiError(statusCode: 401, message: "bad invite") }
        )
        #expect(unauthorized == .unauthorized)
        #expect(unauthorized.text != nil)

        let failed = await CoachUsageStatus.load(
            backend: { backend },
            fetch: { _ in throw AppError.apiError(statusCode: 500, message: "server error") }
        )
        #expect(failed == .failed)
        #expect(failed.text != nil)

        let none = await CoachUsageStatus.load(backend: { nil }, fetch: { _ in usage })
        #expect(none == .unknown)
        #expect(none.text == nil)
    }

    @Test func failedInviteKeychainWriteKeepsDraftUncommittedAndAllowsResubmitRetry() async throws {
        let keychain = MemoryKeychain()
        let settings = try makeSettings(initialInvite: "", keychain: keychain)
        let recorded = Recorded<CoachBackend>()
        let controller = makeController(recorded: recorded)

        controller.load(settings: settings)
        await controller.usageTask?.value
        #expect(recorded.values.isEmpty)

        keychain.failWrite = .locked
        controller.editInvite("synthetic-invite")
        controller.commitInvite(settings: settings, forceReload: true)
        await controller.usageTask?.value

        // Write failed: invite is NOT committed, error surfaces, draft stays intact, usage was NOT sent.
        #expect(keychain.writeAttempts == 1)
        #expect(controller.committedInvite.isEmpty)
        #expect(controller.inviteDraft == "synthetic-invite")
        if case .keychainAccessFailed(let reason) = controller.error {
            #expect(reason == KeychainFailureReason.locked.rawValue)
        } else {
            Issue.record("expected keychainAccessFailed error")
        }
        #expect(recorded.values.isEmpty)
        #expect(settings.credentials.readKey(for: .meetingCoach) == .absent)

        // Re-submitting the exact same invite after Keychain recovers retries and succeeds.
        keychain.failWrite = nil
        controller.commitInvite(settings: settings, forceReload: true)
        await controller.usageTask?.value

        #expect(keychain.writeAttempts == 2)
        #expect(controller.committedInvite == "synthetic-invite")
        #expect(controller.inviteDraft == "synthetic-invite")
        #expect(controller.error == nil)
        #expect(settings.credentials.readKey(for: .meetingCoach) == .found("synthetic-invite"))
        #expect(recorded.values.map(\.token) == ["synthetic-invite"])
    }

    @Test func disappearWithFailedInviteKeychainWriteDoesNotMarkCommitted() throws {
        let keychain = MemoryKeychain()
        let settings = try makeSettings(initialInvite: "old-invite", keychain: keychain)
        let recorded = Recorded<CoachBackend>()
        let controller = makeController(recorded: recorded)

        controller.load(settings: settings)
        let writesBeforeEdit = keychain.writeAttempts

        keychain.failWrite = .transient
        controller.editInvite("new-invite")
        controller.disappear(settings: settings)

        #expect(keychain.writeAttempts == writesBeforeEdit + 1)
        #expect(controller.committedInvite == "old-invite")
        #expect(controller.inviteDraft == "new-invite")
        if case .keychainAccessFailed(let reason) = controller.error {
            #expect(reason == KeychainFailureReason.transient.rawValue)
        } else {
            Issue.record("expected keychainAccessFailed error")
        }
        #expect(settings.credentials.readKey(for: .meetingCoach) == .found("old-invite"))
    }

    @Test func failedInviteKeychainReadOnLoadSurfacesError() throws {
        let keychain = MemoryKeychain()
        keychain.failRead = .denied
        let settings = try makeSettings(initialInvite: "", keychain: keychain)
        let recorded = Recorded<CoachBackend>()
        let controller = makeController(recorded: recorded)

        controller.load(settings: settings)

        #expect(controller.committedInvite.isEmpty)
        #expect(controller.inviteDraft.isEmpty)
        if case .keychainAccessFailed(let reason) = controller.error {
            #expect(reason == KeychainFailureReason.denied.rawValue)
        } else {
            Issue.record("expected keychainAccessFailed error")
        }
    }
}
