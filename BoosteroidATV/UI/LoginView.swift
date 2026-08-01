import SwiftUI

/// The app's very first screen — no separate splash/"tap to sign in" screen
/// in front of it. Design decision: get straight to the email/password form,
/// no extra remote click needed to reveal it.
struct LoginView: View {
    @Environment(AuthManager.self) var authManager
    @State private var email: String = ""
    @State private var password: String = ""

    var body: some View {
        ZStack {
            BoosteroidTheme.background.ignoresSafeArea()
            switch authManager.loginPhase {
            case .credentialsEntry:
                credentialsEntry
            case .exchangingTokens:
                exchangingView
            case .failed(let message):
                failedView(message: message)
            }
        }
    }

    // MARK: Credentials Entry
    //
    // CONFIRMED 2026-07-27/28 by capturing the real Android TV app's traffic
    // (see tools/android-tv-capture/): a direct email/password login, no
    // Cloudflare Turnstile challenge involved (that only gates the
    // browser-facing /auth/login page, not this REST endpoint) — exactly
    // what that app's own "Sign in Manually" screen does.
    private var credentialsEntry: some View {
        VStack(spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(BoosteroidTheme.brandGradient)
                Text("BoosteroidTV")
                    .foregroundStyle(.white)
            }
            .font(.title2.weight(.bold))

            Text("Sign in to Boosteroid")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(spacing: 16) {
                // .textInputAutocapitalization(.never) matters here: without
                // it, tvOS's on-screen keyboard capitalizes the first letter
                // by default, silently turning "name@x.com" into
                // "Name@x.com" — a real reported symptom ("we could not find
                // those credentials" with a confirmed-correct password) that
                // this fixes.
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .frame(maxWidth: 600)
            .padding(.top, 8)

            Button("Sign In") {
                authManager.submitCredentials(email: email, password: password)
            }
            // .bordered (not .borderedProminent) + .gray: gives the standard
            // tvOS look used everywhere else in the app — translucent gray
            // fill with white text by default, and the system auto-inverts
            // to a solid white fill with dark text on focus. borderedProminent
            // keeps a solid fill at all times, so tint(.white) here produced
            // a white background with white label text — invisible.
            .buttonStyle(.bordered)
            .tint(.gray)
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
        }
        .padding(60)
        .frame(maxWidth: 760)
    }

    // MARK: Exchanging Tokens

    private var exchangingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2)
                .tint(.white)
            Text("Signing in...")
                .font(.title2)
                .foregroundStyle(.white)
        }
    }

    // MARK: Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.yellow)
            Text("Sign In Failed")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
            // Diagnostic messages (raw response bodies) can be long — scroll
            // rather than clip off-screen.
            ScrollView {
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 400)

            Button("Try Again") { authManager.login() }
                .buttonStyle(.bordered)
                .tint(.gray)
        }
        .padding(80)
    }
}
