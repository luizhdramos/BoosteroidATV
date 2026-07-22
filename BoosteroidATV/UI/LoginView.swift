import SwiftUI

struct LoginView: View {
    @Environment(AuthManager.self) var authManager
    @State private var cookieInput: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch authManager.loginPhase {
            case .idle:
                loginPrompt
            case .manualCookieEntry:
                manualCookieEntry
            case .exchangingTokens:
                exchangingView
            case .failed(let message):
                failedView(message: message)
            }
        }
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

    // MARK: Manual Cookie Entry
    //
    // CONFIRMED 2026-07-22: tvOS ships no WebKit at all (no WKWebView, no
    // SFSafariViewController, and ASWebAuthenticationSession is explicitly
    // unavailable on tvOS) — there is no way to render Boosteroid's
    // Cloudflare-Turnstile-gated login page inside this app. Instead, the
    // user completes the real login in a browser on another device and
    // pastes the resulting `Cookie` request header here. Apple TV's "Type on
    // iPhone" feature (triggered automatically when a text field is focused)
    // makes pasting a long value into the field below painless.
    private var manualCookieEntry: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("Sign in on another device")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                instructionRow(number: 1, text: "On your phone or computer, open \(BoosteroidAuth.loginStartUrl) and log in.")
                instructionRow(number: 2, text: "Open your browser's developer tools (Network tab), click any request to cloud.boosteroid.com/api/…, and copy the full 'cookie' request header value.")
                instructionRow(number: 3, text: "Paste it into the field below and select Sign In.")
            }
            .font(.body)
            .foregroundStyle(.secondary)

            TextField("Paste the Cookie header value here", text: $cookieInput)
                .font(.caption.monospaced())

            HStack(spacing: 24) {
                Button("Sign In") { authManager.submitCookieHeader(cookieInput) }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(cookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { authManager.cancelLogin() }
                    .buttonStyle(.bordered)
                    .tint(.gray)
            }
        }
        .padding(80)
        .frame(maxWidth: 1100, alignment: .leading)
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number).")
                .fontWeight(.semibold)
            Text(text)
        }
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
            // Diagnostic messages (response body, parsed cookie names) can be
            // long — scroll rather than clip off-screen.
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
