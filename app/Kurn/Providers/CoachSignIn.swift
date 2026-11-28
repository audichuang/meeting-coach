//
//  CoachSignIn.swift
//  Kurn
//
//  Sign in with Apple for the meeting coach. Apple's identity token expires in
//  minutes, so it is traded once at the Worker (`POST /v1/auth/apple`) for the
//  Worker's own session token, which lives where build 1 kept the invite code
//  (the Keychain, `AIProvider.meetingCoach`'s account) and is sent as the
//  bearer. The Worker still accepts a build 1 invite code there, so an
//  upgraded install counts as signed in until the Worker drops invites.
//

import AuthenticationServices
import Foundation
import KurnCore

enum CoachSignIn {
    /// The Worker's answer to the exchange.
    struct Session: Decodable, Equatable, Sendable {
        let token: String
        let email: String?
    }

    /// What Apple handed over, as plain values so tests can build one.
    struct AppleCredential: Sendable {
        let userID: String
        let identityToken: Data?
        let fullName: PersonNameComponents?
        let email: String?

        init(userID: String, identityToken: Data?, fullName: PersonNameComponents?, email: String?) {
            self.userID = userID
            self.identityToken = identityToken
            self.fullName = fullName
            self.email = email
        }

        init(_ credential: ASAuthorizationAppleIDCredential) {
            self.init(userID: credential.user, identityToken: credential.identityToken,
                      fullName: credential.fullName, email: credential.email)
        }
    }

    typealias Exchange = @Sendable (_ identityToken: String) async throws -> Session

    /// Signed in when the Keychain holds a Worker token (or a build 1 invite code);
    /// the DEBUG invite override counts too, so the simulator can show the signed-in state.
    @MainActor
    static func isSignedIn(settings: AppSettings) -> Bool {
        CoachBackend.debugOverride("KURN_DEBUG_COACH_INVITE") != nil || settings.credentials.hasKey(for: .meetingCoach)
    }

    /// Who is signed in, for Settings.
    @MainActor
    static func accountLabel(settings: AppSettings) -> String {
        settings.coachAccountLabel.isEmpty
            ? NSLocalizedString("settings.meeting_coach_signed_in", comment: "Signed in, no name known")
            : settings.coachAccountLabel
    }

    /// `POST /v1/auth/apple`: no bearer, only the Access headers of the build's own Worker.
    static func exchange(
        identityToken: String,
        config: CoachAccess.Config? = CoachAccess.config(),
        serverOverride: String? = CoachBackend.debugOverride("KURN_DEBUG_COACH_SERVER_URL"),
        session: URLSession = .shared
    ) async throws -> Session {
        guard let base = serverOverride.flatMap(CoachBackend.workerBaseURL) ?? config?.baseURL else {
            throw CoachBackend.NotConfigured()
        }
        var request = URLRequest(url: base.appending(path: "auth/apple"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["identity_token": identityToken])
        if let config, CoachAccess.sameOrigin(config.baseURL, base) {
            for (name, value) in config.headers { request.setValue(value, forHTTPHeaderField: name) }
        }
        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)
        return try JSONDecoder().decode(Session.self, from: data)
    }

    /// Trades the Apple credential for a Worker session and stores it. Throws without
    /// touching what is stored, so a failed attempt leaves the previous sign-in in place.
    @MainActor
    static func signIn(
        _ credential: AppleCredential,
        settings: AppSettings,
        exchange: Exchange = { try await CoachSignIn.exchange(identityToken: $0) }
    ) async throws(AppError) {
        guard let data = credential.identityToken, let identityToken = String(data: data, encoding: .utf8) else {
            throw .authenticationFailed(NSLocalizedString("settings.meeting_coach_sign_in_failed", comment: "Sign in failed"))
        }
        let session: Session
        do {
            session = try await exchange(identityToken)
        } catch {
            throw .authenticationFailed(CoachBackend.explained(error).localizedDescription)
        }
        if case .failed(let reason) = settings.credentials.saveKey(session.token, for: .meetingCoach) {
            throw .keychainAccessFailed(reason.rawValue)
        }
        settings.coachAppleUserID = credential.userID
        // Apple sends the name and email only on the first authorization; the Worker remembers the email.
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) } ?? ""
        settings.coachAccountLabel = [name, credential.email ?? "", session.email ?? ""].first { !$0.isEmpty } ?? ""
        settings.coachSignInPromptShown = true
    }

    @MainActor
    static func signOut(settings: AppSettings) {
        settings.credentials.saveKey("", for: .meetingCoach)
        settings.coachAppleUserID = ""
        settings.coachAccountLabel = ""
        // Settings offers sign-in again; the first-launch screen must not pop over it.
        settings.coachSignInPromptShown = true
    }

    /// Signs out once Apple says the credential was revoked or no longer exists. An install with
    /// no Apple user id (build 1 invite, DEBUG) is left alone.
    @MainActor
    static func signOutIfRevoked(
        settings: AppSettings,
        state: @Sendable (String) async -> ASAuthorizationAppleIDProvider.CredentialState = { userID in
            // Not the async `credentialState(forUserID:)`: Apple reports `.notFound` together with
            // an error, which that overload turns into a throw and loses the state.
            await withCheckedContinuation { continuation in
                ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                    continuation.resume(returning: state)
                }
            }
        }
    ) async {
        let userID = settings.coachAppleUserID
        guard !userID.isEmpty else { return }
        let current = await state(userID)
        if current == .revoked || current == .notFound, settings.coachAppleUserID == userID {
            signOut(settings: settings)
        }
    }
}
