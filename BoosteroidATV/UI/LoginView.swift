import SwiftUI

struct LoginView: View {
    @Environment(AuthManager.self) var authManager
    @State private var currentURL: URL?
    @State private var captureTrigger = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch authManager.loginPhase {
            case .idle:
                loginPrompt
            case .awaitingWebLogin(let url):
                webLogin(url: url)
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

    // MARK: Web Login
    //
    // TODO(protocol): the "I'm signed in" button below exists only because we
    // don't yet have automatic success detection (see WebLoginCaptureView's
    // header comment). Once we know the real signal, replace this with
    // automatic capture and drop the manual button + debug URL text.
    private func webLogin(url: URL) -> some View {
        ZStack(alignment: .bottom) {
            WebLoginCaptureView(
                startURL: url,
                captureTrigger: captureTrigger,
                onCurrentURLChanged: { currentURL = $0 },
                onCapture: { cookies in authManager.receivedWebLoginCookies(cookies) }
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                if let currentURL {
                    Text(currentURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 24) {
                    Button("I'm signed in") { captureTrigger += 1 }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    Button("Cancel") { authManager.cancelLogin() }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                }
            }
            .padding(24)
            .background(.black.opacity(0.6))
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
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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
