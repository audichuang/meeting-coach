//
//  CoachServerSettingsTests.swift
//  KurnTests
//
//  The meeting coach's Sign in with Apple storage and the usage row in
//  Recording Settings. The Worker address is fixed at build time.
//

import AuthenticationServices
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

    // MARK: - Sign in with Apple

    private func credential(name: String? = nil, email: String? = nil, token: String? = "apple.jwt") -> CoachSignIn.AppleCredential {
        CoachSignIn.AppleCredential(
            userID: "001234.synthetic",
            identityToken: token.map { Data($0.utf8) },
            fullName: name.map { var c = PersonNameComponents(); c.givenName = $0; return c },
            email: email
        )
    }

    @Test func signInStoresTheWorkerTokenAndWhoSignedIn() async throws {
        let settings = try makeSettings()
        let sent = Recorded<String>()
        try await CoachSignIn.signIn(credential(name: "Synthetic"), settings: settings) { identityToken in
            sent.append(identityToken)
            return .init(token: "mcs_session", email: "user@example.test")
        }
        #expect(sent.values == ["apple.jwt"])
        #expect(settings.credentials.readKey(for: .meetingCoach) == .found("mcs_session"))
        #expect(settings.coachAppleUserID == "001234.synthetic")
        #expect(settings.coachAccountLabel == "Synthetic")
        #expect(settings.coachSignInPromptShown)
        #expect(CoachSignIn.isSignedIn(settings: settings))
    }

    @Test func accountLabelFallsBackToAppleEmailThenWorkerEmail() async throws {
        let settings = try makeSettings()
        try await CoachSignIn.signIn(credential(email: "apple@example.test"), settings: settings) { _ in
            .init(token: "t1", email: "worker@example.test")
        }
        #expect(settings.coachAccountLabel == "apple@example.test")
        // A later sign-in: Apple sends no name or email any more; the Worker still knows the email.
        try await CoachSignIn.signIn(credential(), settings: settings) { _ in .init(token: "t2", email: "worker@example.test") }
        #expect(settings.coachAccountLabel == "worker@example.test")
        try await CoachSignIn.signIn(credential(), settings: settings) { _ in .init(token: "t3", email: nil) }
        #expect(settings.coachAccountLabel.isEmpty)
        #expect(CoachSignIn.accountLabel(settings: settings) == NSLocalizedString("settings.meeting_coach_signed_in", comment: ""))
    }

    @Test func failedExchangeKeepsThePreviousSignIn() async throws {
        let settings = try makeSettings(initialInvite: "mc_build1_invite")
        await #expect(throws: AppError.self) {
            try await CoachSignIn.signIn(self.credential(), settings: settings) { _ in
                throw AppError.apiError(statusCode: 401, message: "bad signature")
            }
        }
        #expect(settings.credentials.readKey(for: .meetingCoach) == .found("mc_build1_invite"))
        #expect(settings.coachAppleUserID.isEmpty)
    }

    @Test func missingIdentityTokenNeverReachesTheWorker() async throws {
        let settings = try makeSettings()
        let sent = Recorded<String>()
        await #expect(throws: AppError.self) {
            try await CoachSignIn.signIn(self.credential(token: nil), settings: settings) { token in
                sent.append(token)
                return .init(token: "x", email: nil)
            }
        }
        #expect(sent.values.isEmpty)
        #expect(!CoachSignIn.isSignedIn(settings: settings))
    }

    @Test func keychainWriteFailureSurfacesAndRecordsNoUser() async throws {
        let keychain = MemoryKeychain()
        let settings = try makeSettings(keychain: keychain)
        keychain.failWrite = .locked
        do {
            try await CoachSignIn.signIn(credential(), settings: settings) { _ in .init(token: "mcs_session", email: nil) }
            Issue.record("expected a throw")
        } catch {
            guard case .keychainAccessFailed(let reason) = error else { Issue.record("got \(error)"); return }
            #expect(reason == KeychainFailureReason.locked.rawValue)
        }
        #expect(settings.coachAppleUserID.isEmpty)
    }

    @Test func signOutClearsTokenAndAccount() async throws {
        let settings = try makeSettings()
        try await CoachSignIn.signIn(credential(name: "Synthetic"), settings: settings) { _ in .init(token: "mcs", email: nil) }
        CoachSignIn.signOut(settings: settings)
        #expect(settings.credentials.readKey(for: .meetingCoach) == .absent)
        #expect(settings.coachAppleUserID.isEmpty)
        #expect(settings.coachAccountLabel.isEmpty)
        #expect(!CoachSignIn.isSignedIn(settings: settings))
    }

    @Test func revokedOrMissingAppleCredentialSignsOut() async throws {
        for (state, signedOut) in [(ASAuthorizationAppleIDProvider.CredentialState.revoked, true),
                                   (.notFound, true), (.authorized, false), (.transferred, false)] {
            let settings = try makeSettings()
            try await CoachSignIn.signIn(credential(), settings: settings) { _ in .init(token: "mcs", email: nil) }
            await CoachSignIn.signOutIfRevoked(settings: settings) { userID in
                #expect(userID == "001234.synthetic")
                return state
            }
            #expect(CoachSignIn.isSignedIn(settings: settings) == !signedOut, "\(state.rawValue)")
        }
    }

    @Test func build1InviteIsSignedInAndNeverCheckedWithApple() async throws {
        let settings = try makeSettings(initialInvite: "mc_build1_invite")
        let asked = Recorded<String>()
        await CoachSignIn.signOutIfRevoked(settings: settings) { userID in
            asked.append(userID)
            return .revoked
        }
        #expect(asked.values.isEmpty)
        #expect(CoachSignIn.isSignedIn(settings: settings))
        #expect(!CoachSignInPromptView.isNeeded(settings: settings, arguments: []))
    }

    @Test func firstLaunchPromptShowsOnceWhileSignedOut() throws {
        let settings = try makeSettings()
        #expect(CoachSignInPromptView.isNeeded(settings: settings, arguments: []))
        #expect(!CoachSignInPromptView.isNeeded(settings: settings, arguments: ["UI-Testing-Screenshots"]))
        settings.coachSignInPromptShown = true
        #expect(!CoachSignInPromptView.isNeeded(settings: settings, arguments: []))
    }

    // MARK: - Settings controller

    @Test func usageLoadsWithTheStoredTokenAndStopsAfterSignOut() async throws {
        let settings = try makeSettings(initialInvite: "mcs_session")
        let recorded = Recorded<CoachBackend>()
        let controller = makeController(recorded: recorded)

        controller.load(settings: settings)
        await controller.usageTask?.value
        #expect(recorded.values.map(\.token) == ["mcs_session"])
        #expect(controller.usage != .unknown)

        controller.signOut(settings: settings)
        await controller.usageTask?.value
        #expect(controller.usage == .unknown)
        #expect(recorded.values.count == 1)
    }

    @Test func failedKeychainReadOnLoadSurfacesError() throws {
        let keychain = MemoryKeychain()
        keychain.failRead = .denied
        let settings = try makeSettings(keychain: keychain)
        let controller = makeController(recorded: Recorded<CoachBackend>())

        controller.load(settings: settings)

        if case .keychainAccessFailed(let reason) = controller.error {
            #expect(reason == KeychainFailureReason.denied.rawValue)
        } else {
            Issue.record("expected keychainAccessFailed error")
        }
    }
}
