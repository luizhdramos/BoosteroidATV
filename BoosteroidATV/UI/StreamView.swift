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
    @State private var queueAttempt = 0
    @State private var queueStatus = ""
    @State private var queueStartedAt = Date()

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
                        // Boosteroid's confirmed last-session API has no
                        // numeric queue-position field (the web UI's
                        // "Posição na fila" is pushed over a WebSocket this
                        // app can't capture) — so this is the most honest
                        // status we can show: still queued, how long, and a
                        // way out instead of a silent spinner.
                        if queueAttempt > 0 {
                            VStack(spacing: 8) {
                                Text("Still in queue (status: \(queueStatus)) — waited \(Int(Date().timeIntervalSince(queueStartedAt)))s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Boosteroid's free-tier queue position can rise as paying-tier users join — this can take a while or may not clear at all.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 120)
                            }
                        }
                        Button("Cancel") { onDismiss() }
                            .buttonStyle(.bordered)
                            .tint(.gray)
                            .padding(.top, 8)
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
        queueStartedAt = Date()
        do {
            let cookies = try await authManager.resolveCookies()
            let client = BoosteroidClient()
            // createAndAwaitSession enqueues, polls the confirmed
            // last-session endpoint until the queue clears (or 180s
            // elapses), then fetches session/details. TODO(protocol):
            // session/details' success body (nodeBaseUrl) still isn't
            // captured, so this currently throws .notImplemented right at
            // the point queue wait finishes — see BoosteroidClient.swift.
            let session = try await client.createAndAwaitSession(
                SessionCreateRequest(gameId: game.id, settings: settings),
                cookies: cookies,
                onPoll: { info, attempt in
                    queueAttempt = attempt
                    queueStatus = info.status
                }
            )
            await controller.connect(session: session, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
