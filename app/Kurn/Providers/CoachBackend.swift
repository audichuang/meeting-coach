//
//  CoachBackend.swift
//  Kurn
//
//  Where the meeting coach's OpenAI traffic goes. Release builds only talk to
//  the project's Cloudflare Worker (backend/), authenticated with an invite
//  code; the Worker holds the OpenAI key, meters spend and refuses calls past
//  the monthly cap (HTTP 402). DEBUG builds may instead go straight to OpenAI
//  with a pasted key, which is how simulator tests run without a Worker.
//

import Foundation
import KurnCore

struct CoachBackend: Sendable, Equatable {
    /// Ends in `/v1`: the Worker's routes mirror OpenAI's paths under it.
    let baseURL: URL
    /// The invite code for the Worker, or the OpenAI key when direct.
    let token: String
    let viaWorker: Bool

    /// `UserDefaults` key of the server URL the user entered in Settings.
    static let serverURLKey = "settings.coachServerURL"

    /// The configured backend, or `nil` when the coach has nowhere to send audio.
    /// Read off the main actor too (ProviderFactory), so it reads `UserDefaults`
    /// and the Keychain directly rather than `AppSettings`.
    static func current(defaults: UserDefaults = .standard) -> CoachBackend? {
        let server = defaults.string(forKey: serverURLKey) ?? ""
        let invite = KeychainManager.shared.value(for: AIProvider.meetingCoach.keychainAccount) ?? ""
        if let worker = workerBackend(serverURL: server, invite: invite) {
            return worker
        }
        #if DEBUG
        let key = ProviderFactory.storedAPIKey(for: .openAI)
        if !key.isEmpty, let base = URL(string: AIProvider.openAI.baseURLString) {
            return CoachBackend(baseURL: base, token: key, viaWorker: false)
        }
        #endif
        return nil
    }

    /// Resolves a Worker backend from explicit server URL and invite strings,
    /// applying the existing HTTPS/host validation and DEBUG env overrides.
    static func workerBackend(serverURL: String, invite: String) -> CoachBackend? {
        let server = debugOverride("KURN_DEBUG_COACH_SERVER_URL") ?? serverURL
        let token = debugOverride("KURN_DEBUG_COACH_INVITE") ?? invite
        guard let base = workerBaseURL(server), !token.isEmpty else { return nil }
        return CoachBackend(baseURL: base, token: token, viaWorker: true)
    }

    /// DEBUG only: an unsigned simulator build cannot reach the Keychain.
    private static func debugOverride(_ key: String) -> String? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
        #endif
        return nil
    }

    /// The Worker's 402/401 in the user's words, keeping the status code for `isCoachQuotaExhausted`.
    static func explained(_ error: Error) -> Error {
        if error.isCoachQuotaExhausted {
            return AppError.apiError(statusCode: 402, message: NSLocalizedString("coach.error.quota", comment: "Monthly allowance used up"))
        }
        if error.isCoachUnauthorized {
            return AppError.apiError(statusCode: 401, message: NSLocalizedString("coach.error.unauthorized", comment: "Invite code rejected"))
        }
        return error
    }

    /// `https://host[/path]` → `https://host[/path]/v1`; anything else is `nil`.
    static func workerBaseURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard LLMHTTP.isValidBaseURL(trimmed), let url = URL(string: trimmed), url.scheme == "https" else { return nil }
        return url.lastPathComponent == "v1" ? url : url.appending(path: "v1")
    }

    /// The provider the post-meeting pipeline runs under, with this backend's base URL.
    var provider: AIProvider {
        var provider = AIProvider.meetingCoach
        provider.baseURLString = baseURL.absoluteString
        return provider
    }

    /// The Worker's `GET /v1/usage`: this month's spend and cap.
    struct Usage: Decodable, Sendable, Equatable {
        struct Period: Decodable, Sendable, Equatable { let usd: Double }
        let month: Period
        let monthlyCapUSD: Double

        enum CodingKeys: String, CodingKey {
            case month
            case monthlyCapUSD = "monthly_cap_usd"
        }
    }

    func usage(session: URLSession = .shared) async throws -> Usage {
        var request = URLRequest(url: baseURL.appending(path: "usage"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)
        return try JSONDecoder().decode(Usage.self, from: data)
    }
}

/// The formal transcript's client, with the Worker's refusals explained for the alert.
struct CoachTranscriptionProvider: TranscriptionProvider {
    let base: any TranscriptionProvider
    var provider: AIProvider { base.provider }

    func transcribe(audioData: Data, fileName: String, language: MeetingLanguage) async throws -> RawTranscript {
        do {
            return try await base.transcribe(audioData: audioData, fileName: fileName, language: language)
        } catch {
            throw CoachBackend.explained(error)
        }
    }
}

extension AIProvider {
    /// Not a user-selectable provider: the identity the meeting coach's
    /// post-meeting transcription and summary run under. `ProviderFactory`
    /// resolves its base URL and token through `CoachBackend.current()` at call
    /// time, so a resumed run follows the current Settings. The Keychain
    /// account holds the invite code.
    static let meetingCoach = AIProvider(
        id: "meetingCoach",
        displayName: "Meeting coach",
        kind: .openAICompatible,
        baseURLString: "",
        legacyKeychainAccount: "meeting_coach_invite"
    )
}

extension Error {
    /// The Worker's answer once this month's cap is spent.
    var isCoachQuotaExhausted: Bool {
        if case AppError.apiError(402, _)? = self as? AppError { return true }
        return false
    }

    /// The Worker does not know the invite code (or it was revoked).
    var isCoachUnauthorized: Bool {
        if case AppError.apiError(401, _)? = self as? AppError { return true }
        return false
    }
}
