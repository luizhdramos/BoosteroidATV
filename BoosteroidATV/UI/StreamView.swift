import SwiftUI

/// TODO(protocol): this drives StreamController against BoosteroidClient, both
/// of which currently throw BoosteroidClientError.notImplemented / do nothing
/// useful yet. The UI shell (loading state, error state, video surface, basic
/// pause overlay) is here so the rest of the app can be wired up and tested as
/// soon as the real session-creation and signaling calls exist.
struct StreamView: View {
    let game: GameInfo
    let settings: StreamSettings
    let onDismiss: () -> Void

    @Environment(AuthManager.self) var authManager
    @State private var controller = StreamController()
    @State private var showOverlay = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch controller.state {
            case .idle, .connecting:
                if let errorMessage {
                    statusView(title: "Couldn't Start Session", message: errorMessage)
                } else {
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(2).tint(.white)
                        Text("Connecting to \(game.title)...")
                            .foregroundStyle(.white)
                    }
                }
            case .streaming:
                VideoSurfaceViewRepresentable(streamController: controller, showOverlay: showOverlay)
                    .ignoresSafeArea()
                if showOverlay {
                    overlay
                }
            case .disconnected(let reason):
                statusView(title: "Disconnected", message: reason)
            case .failed(let message):
                statusView(title: "Stream Failed", message: message)
            }
        }
        .task { await start() }
        .onDisappear { controller.disconnect() }
    }

    private var overlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 24) {
                Text(String(format: "%.0f fps", controller.stats.fps))
                Text("\(controller.stats.bitrateKbps) kbps")
                Text(String(format: "%.0f ms", controller.stats.rttMs))
                Button("Exit Session") {
                    controller.disconnect()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding()
            .background(.black.opacity(0.7))
            .foregroundStyle(.white)
        }
    }

    private func statusView(title: String, message: String) -> some View {
        VStack(spacing: 24) {
            Text(title).font(.title.weight(.semibold)).foregroundStyle(.white)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 80)
            Button("Close") { onDismiss() }
                .buttonStyle(.bordered)
                .tint(.gray)
        }
    }

    private func start() async {
        do {
            let cookies = try await authManager.resolveCookies()
            let client = BoosteroidClient()
            let session = try await client.createSession(
                SessionCreateRequest(gameId: game.id, settings: settings),
                cookies: cookies
            )
            await controller.connect(session: session, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
