import SwiftUI

/// Drives StreamController against BoosteroidClient's CONFIRMED,
/// end-to-end-verified session lifecycle (enqueue -> poll last-session ->
/// session/details -> WebRTC signaling — see BoosteroidClient.swift's
/// Session Lifecycle note; verified 2026-07-22 against a real, genuinely
/// playable PRAGMATA session). Also drives BoosteroidRealtimeClient
/// separately, purely to show a live numeric queue position while waiting.
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
    @State private var queuePosition: Int?
    @State private var queueEta: Int?
    @State private var realtimeClient = BoosteroidRealtimeClient()

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
                        // Live connect stage, so a stuck session shows WHERE
                        // it's stuck (control channel / WebRTC step) instead of
                        // spinning silently.
                        if !controller.stage.isEmpty {
                            Text(controller.stage)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 80)
                        }
                        // last-session (polled by createAndAwaitSession) is
                        // the CONFIRMED authoritative "are we still queued"
                        // signal (EN -> LI), but has no numeric position.
                        // BoosteroidRealtimeClient's WebSocket feed supplies
                        // that number separately when available — CONFIRMED
                        // real-world behavior: queue position can rise as
                        // well as fall (higher-tier accounts join ahead),
                        // even on a paid account, so this can take a while.
                        if queueAttempt > 0 || queuePosition != nil {
                            VStack(spacing: 8) {
                                if let queuePosition {
                                    Text("Queue position: \(queuePosition)" + (queueEta.map { " — ~\($0)s" } ?? ""))
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                }
                                Text("Status: \(queueStatus.isEmpty ? "waiting" : queueStatus) — waited \(Int(Date().timeIntervalSince(queueStartedAt)))s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Cancel") { onDismiss() }
                            .buttonStyle(.bordered)
                            .tint(.gray)
                            .padding(.top, 8)
                    }
                }
            case .streaming:
                VideoSurfaceViewRepresentable(streamController: controller, showOverlay: showOverlay, onMenu: { showOverlay.toggle() })
                    .ignoresSafeArea()
                // Compact performance overlay — only when enabled in Settings.
                if settings.showStatsOverlay {
                    statsOverlay
                }
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

    /// Discreet single-line performance overlay pinned to the top-left edge:
    /// "Bitrate: 2.3 Mbps | Stream FPS: 120 | Latency: 13ms". Codec is omitted
    /// (Apple TV only ever gets H.264).
    private var statsOverlay: some View {
        let mbps = Double(controller.stats.bitrateKbps) / 1000
        let line = "Bitrate: \(String(format: "%.1f", mbps)) Mbps | Stream FPS: \(controller.streamFps) | Latency: \(controller.rttMs)ms"
        return VStack {
            HStack {
                Text(line)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule())
                Spacer()
            }
            Spacer()
        }
        .padding(.top, 8)
        .padding(.leading, 8)
        .allowsHitTesting(false)
    }

    private var overlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 28) {
                Text(game.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(Int(controller.stats.fps)) fps · \(controller.stats.bitrateKbps) kbps · \(controller.stats.resolutionWidth)x\(controller.stats.resolutionHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Button("Resume") { showOverlay = false }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    Button("Leave Game") {
                        controller.disconnect()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .padding(48)
        }
        // Menu/back on the remote closes the menu (Resume) instead of exiting.
        .onExitCommand { showOverlay = false }
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
        // Best-effort: the numeric queue position only comes from
        // BoosteroidRealtimeClient's WebSocket feed, which is a "nice to
        // have" — the actual queue -> active detection below relies solely
        // on the CONFIRMED-reliable last-session polling and doesn't depend
        // on this succeeding.
        let realtimeTask = Task { await watchQueuePosition() }
        defer {
            realtimeTask.cancel()
            Task { await realtimeClient.disconnect() }
        }
        do {
            let cookies = try await authManager.resolveCookies()
            let client = BoosteroidClient()
            // createAndAwaitSession enqueues, then polls the CONFIRMED
            // last-session endpoint (EN = queued, LI = active) until ready
            // or 180s elapses, then fetches session/details for the real
            // node host — see BoosteroidClient.swift's Session Lifecycle
            // note for how this was verified end-to-end against a real,
            // genuinely-playable session.
            let session = try await client.createAndAwaitSession(
                SessionCreateRequest(gameId: game.id, settings: settings),
                cookies: cookies,
                onPoll: { info, attempt in
                    queueAttempt = attempt
                    queueStatus = info.status
                }
            )
            await controller.connect(session: session, settings: settings, cookies: cookies)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Connects to Boosteroid's real-time WebSocket (see
    /// BoosteroidRealtimeClient) purely to surface a live numeric queue
    /// position/eta in the UI. Failure here is silent by design — this is
    /// cosmetic, not load-bearing; `start()`'s last-session polling is what
    /// actually decides when to proceed.
    private func watchQueuePosition() async {
        guard let (userId, token) = try? await authManager.resolveRealtimeCredentials() else { return }
        guard let targetAppId = Int(game.id) else { return }
        for await event in await realtimeClient.connect(userId: userId, token: token) {
            if Task.isCancelled { break }
            switch event {
            case .queueUpdate(let appId, let position, let eta):
                guard appId == targetAppId else { continue }
                queuePosition = position
                queueEta = eta
            case .raw, .closed, .failed:
                continue
            }
        }
    }
}
