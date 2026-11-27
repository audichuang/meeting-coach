//
//  CoachServerSettingsTests.swift
//  KurnTests
//
//  B2: editing the meeting coach server URL never persists a half-typed host or
//  sends the invite code to it; persistence and `GET /v1/usage` fire only once
//  the user commits the URL (on submit or focus loss), preserving HTTPS/host
//  validation.
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
        initialURL: String = "",
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
        if !initialURL.isEmpty {
            settings.coachServerURL = initialURL
        }
        return settings
    }

    private func makeController(
        recorded: Recorded<CoachBackend>,
        status: CoachUsageStatus = .loaded(CoachBackend.Usage(month: .init(usd: 1.25), monthlyCapUSD: 20))
    ) -> CoachServerSettingsController {
        CoachServerSettingsController(
            resolveBackend: { serverURL, invite in
                guard let base = CoachBackend.workerBaseURL(serverURL), !invite.isEmpty else { return nil }
                return CoachBackend(baseURL: base, token: invite, viaWorker: true)
            },
            loadUsage: { backend in
                recorded.append(backend)
                return status
            }
        )
    }

    @Test func intermediateURLKeystrokesDoNotPersistOrSendInvite() async throws {
        let settings = try makeSettings(initialURL: "", initialInvite: "synthetic-invite")
        let recorded = Recorded<CoachBackend>()
        let controller = makeController(recorded: recorded)

        controller.load(settings: settings)
        await controller.usageTask?.value
        #expect(recorded.values.isEmpty)

        // Typing a half-finished valid-looking host must not persist or send the invite.
        controller.editServerURL("https://abc.workers.de")
        await controller.usageTask?.value
        #expect(settings.coachServerURL.isEmpty)
        #expect(recorded.values.isEmpty)

        // Finishing the host and submitting commits once and loads usage once.
        controller.editServerURL("https://abc.workers.dev")
        await controller.usageTask?.value
        #expect(settings.coachServerURL.isEmpty)
        #expect(recorded.values.isEmpty)

        controller.commitServerURL(settings: settings, forceReload: true)
        await controller.usageTask?.value
        #expect(settings.coachServerURL == "https://abc.workers.dev")
        #expect(recorded.values.map(\.baseURL.absoluteString) == ["https://abc.workers.dev/v1"])
        #expect(recorded.values.map(\.token) == ["synthetic-invite"])

        // A focus-loss blur immediately after submit must not trigger a duplicate request.
        controller.commitServerURL(settings: settings, forceReload: false)
        await controller.usageTask?.value
        #expect(recorded.values.count == 1)
    }

    @Test func focusLossCommitsEditedURLAndLoadsUsageOnce() async throws {
        let settings = try makeSettings(initialURL: "", initialInvite: "synthetic-invite")
        let recorded = Recorded<CoachBackend>()
        let controller = makeController(recorded: recorded)

        controller.load(settings: settings)
        await controller.usageTask?.value

        controller.editServerURL("  https://coach.example.test/  ")
        #expect(settings.coachServerURL.isEmpty)
        #expect(recorded.values.isEmpty)

        controller.commitServerURL(settings: settings, forceReload: false)
        await controller.usageTask?.value
        #expect(settings.coachServerURL == "https://coach.example.test/")
        #expect(recorded.values.map(\.baseURL.absoluteString) == ["https://coach.example.test/v1"])

        // Leaving focus again without changes is a no-op.
        controller.commitServerURL(settings: settings, forceReload: false)
        await controller.usageTask?.value
        #expect(recorded.values.count == 1)
    }

    @Test func invalidOrNonHTTPSCommittedURLNeverLoadsUsage() async throws {
        let settings = try makeSettings(initialURL: "https://coach.example.test", initialInvite: "synthetic-invite")
        let recorded = Recorded<CoachBackend>()
        let controller = makeController(recorded: recorded)

        controller.load(settings: settings)
        await controller.usageTask?.value
        #expect(recorded.values.count == 1)
        #expect(controller.usage != .unknown)

        for invalid in ["http://coach.example.test", "not a url", ""] {
            controller.editServerURL(invalid)
            controller.commitServerURL(settings: settings, forceReload: true)
            await controller.usageTask?.value
            #expect(controller.usage == .unknown)
        }
        #expect(recorded.values.count == 1)
    }

    @Test func inviteEditWhileURLIsUncommittedDoesNotSendToUncommittedHost() async throws {
        let settings = try makeSettings(initialURL: "https://old.example.test", initialInvite: "old-invite")
        let recorded = Recorded<CoachBackend>()
        let controller = makeController(recorded: recorded)

        controller.load(settings: settings)
        await controller.usageTask?.value
        #expect(recorded.values.map(\.baseURL.absoluteString) == ["https://old.example.test/v1"])

        // Start typing a new host without committing.
        controller.editServerURL("https://abc.workers.de")
        // Edit invite code without committing URL.
        controller.editInvite("new-invite")
        await controller.usageTask?.value
        #expect(settings.coachServerURL == "https://old.example.test")
        #expect(recorded.values.count == 1)

        // Committing invite while URL draft is still uncommitted does not send to the half-typed URL.
        controller.commitInvite(settings: settings, forceReload: false)
        await controller.usageTask?.value
        #expect(recorded.values.count == 1)

        // Committing the finished URL now sends the new invite to the committed host.
        controller.editServerURL("https://abc.workers.dev")
        controller.commitServerURL(settings: settings, forceReload: false)
        await controller.usageTask?.value
        #expect(recorded.values.map(\.baseURL.absoluteString) == [
            "https://old.example.test/v1",
            "https://abc.workers.dev/v1"
        ])
        #expect(recorded.values.last?.token == "new-invite")
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
        let settings = try makeSettings(initialURL: "https://coach.example.test", initialInvite: "", keychain: keychain)
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
        let settings = try makeSettings(initialURL: "https://coach.example.test", initialInvite: "old-invite", keychain: keychain)
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
        let settings = try makeSettings(initialURL: "https://coach.example.test", initialInvite: "", keychain: keychain)
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
