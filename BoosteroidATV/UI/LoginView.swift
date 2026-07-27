import SwiftUI

struct LoginView: View {
    @Environment(AuthManager.self) var authManager
    @State private var cookieInput: String = ""
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
            case .manualCookieEntry:
                manualCookieEntry
            case .exchangingTokens:
                exchangingView
            case .failed(let message):
                failedView(message: message)
            }
        }
    }

    // MARK: Credentials Entry
    //
    // CONFIRMED 2026-07-27 by capturing the real Android TV app's traffic
    // (see tools/android-tv-capture/): a direct email/password login, no
    // Cloudflare Turnstile challenge involved (that only gates the
    // browser-facing /auth/login page, not this REST endpoint) — exactly
    // what that app's own "Sign in Manually" screen does. This replaces the
    // external-browser-plus-cookie-paste flow as the primary path.
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
                TextField("Email", text: $email)
                    .textContentType(.username)
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

            Button("Trouble signing in? Use cookie method instead") {
                authManager.useManualCookieEntry()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
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

    // MARK: Manual Cookie Entry
    //
    // CONFIRMED 2026-07-22: tvOS ships no WebKit at all (no WKWebView, no
    // SFSafariViewController, and ASWebAuthenticationSession is explicitly
    // unavailable on tvOS) — there is no way to render Boosteroid's
    // Cloudflare-Turnstile-gated login page inside this app. The user instead
    // completes the real login in a browser on another device and gets the
    // resulting cookies here.
    //
    // CONFIRMED on a real Apple TV: pasting the ~4000-character cookie export
    // directly into a text field is NOT reliable — it silently arrived
    // truncated to ~500 characters. Recommend a link instead: the user saves
    // the export to a file (iCloud Drive, a Gist, paste.ee, ...), and only
    // has to type/paste a short URL here, which the app downloads itself.
    // Wrapped in a ScrollView, top-aligned: on a real Apple TV the full
    // step-by-step + field + buttons is taller than the screen, and a plain
    // centered VStack clipped the title and steps off the top edge — leaving
    // only the text field visible. The ScrollView keeps everything reachable
    // (tvOS auto-scrolls to whatever is focused).
    private var manualCookieEntry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in on another device")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("tvOS can't show Boosteroid's login page, so log in elsewhere and bring the cookies here.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                cookieGuide

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Paste the Raw cookie URL (or the cookie text itself)", text: $cookieInput)
                        .font(.caption.monospaced())

                    // Diagnostic: confirms whether the paste actually landed in
                    // the field in full, independent of whether it later parses
                    // — tvOS's remote-driven text input has been unreliable with
                    // very long pasted values in earlier testing.
                    Text("\(cookieInput.count) characters entered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
            .frame(maxWidth: .infinity)
        }
    }

    // Mini step-by-step for getting the raw cookie export, in a distinct card
    // so it reads as a guide rather than blending into the rest of the screen.
    private var cookieGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("How to get your cookies", systemImage: "list.number")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 14) {
                instructionRow(number: 1, text: "On your phone or computer, open \(BoosteroidAuth.loginStartUrl) and log in.")
                instructionRow(number: 2, text: "Add the free \"Cookie-Editor\" browser extension (Chrome, Edge, or Firefox) and open it while you're on cloud.boosteroid.com.")
                instructionRow(number: 3, text: "In Cookie-Editor, tap the Export button and choose \"Export as JSON\" — it copies all your cookies to the clipboard.")
                instructionRow(number: 4, text: "Go to gist.github.com, paste the JSON into a new gist, and create it (a secret gist is fine).")
                instructionRow(number: 5, text: "Open the gist, click the \"Raw\" button, then copy the URL from your browser's address bar.")
                instructionRow(number: 6, text: "Paste that Raw URL into the field below and select Sign In.")
            }
            .font(.body)
            .foregroundStyle(.secondary)

            Label("iCloud Drive / Dropbox share links won't work — they return a web page, not the raw file. Use a Gist \"Raw\" link.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.yellow)
                .padding(.top, 4)
        }
        .padding(28)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.body.weight(.bold))
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(.orange.opacity(0.15), in: Circle())
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
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

            Button("Use cookie method instead") {
                authManager.useManualCookieEntry()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(80)
    }
}
