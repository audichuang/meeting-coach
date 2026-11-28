//
//  CoachSignInButton.swift
//  Kurn
//
//  The "Sign in with Apple" button for the meeting coach, used by the
//  first-launch screen and by Settings → Meeting coach while signed out.
//

import AuthenticationServices
import KurnCore
import SwiftUI

struct CoachSignInButton: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let onSignedIn: () -> Void
    @State private var error: AppError?
    @State private var isSigningIn = false

    init(onSignedIn: @escaping () -> Void = {}) {
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
                let apple = CoachSignIn.AppleCredential(credential)
                isSigningIn = true
                Task {
                    do throws(AppError) {
                        try await CoachSignIn.signIn(apple, settings: settings)
                        onSignedIn()
                    } catch {
                        self.error = error
                    }
                    isSigningIn = false
                }
            case .failure(let failure):
                if (failure as? ASAuthorizationError)?.code == .canceled { return }
                error = .authenticationFailed(failure.localizedDescription)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 48)
        .disabled(isSigningIn)
        .overlay { if isSigningIn { ProgressView() } }
        .errorAlert($error)
    }
}

/// Shown once on first launch while signed out. Recording works without the coach, so it can be skipped.
struct CoachSignInPromptView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.wave.2")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(NSLocalizedString("coach.sign_in.title", comment: "First-launch sign-in title"))
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(NSLocalizedString("coach.sign_in.message", comment: "Why the coach needs sign-in"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            CoachSignInButton { settings.coachSignInPromptShown = true }
            Button(NSLocalizedString("coach.sign_in.later", comment: "Skip sign-in for now")) {
                settings.coachSignInPromptShown = true
            }
            .padding(.bottom)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 480)
    }

    /// Fresh install, signed out, and not a UI test (those launch without a Keychain token).
    @MainActor
    static func isNeeded(settings: AppSettings, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        if arguments.contains(where: { $0.hasPrefix("UI-Testing") || $0 == "-ui_testing" }) { return false }
        #endif
        return !settings.coachSignInPromptShown && !CoachSignIn.isSignedIn(settings: settings)
    }
}
