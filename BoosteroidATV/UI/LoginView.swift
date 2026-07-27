import SwiftUI

struct LoginView: View {
    @Environment(AuthManager.self) var authManager
    @State private var email: String = ""
    @State private var password: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch authManager.loginPhase {
            case .idle:
                loginPrompt
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
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Text("Sign in to Boosteroid")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Same account as the mobile/web app.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

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
            .frame(maxWidth: 700)

            HStack(spacing: 24) {
                Button("Sign In") {
                    authManager.submitCredentials(email: email, password: password)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                Button("Cancel") { authManager.cancelLogin() }
                    .buttonStyle(.bordered)
                    .tint(.gray)
            }
        }
        .padding(80)
    }

    // MARK: Login Prompt

    private var loginPrompt: some View {
        VStack(spacing: 48) {
            VStack(spacing: 12) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white)
                Text("BoosteroidATV")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Cloud Gaming for Apple TV")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button {
                authManager.login()
            } label: {
                Label("Sign in to Boosteroid", systemImage: "person.badge.key")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(80)
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

            HStack(spacing: 24) {
                Button("Try Again") { authManager.login() }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                Button("Cancel") { authManager.cancelLogin() }
                    .buttonStyle(.bordered)
                    .tint(.gray)
            }
        }
        .padding(80)
    }
}
