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
    /// Used only to name an unexpected appId seen in a queue push (see
    /// watchQueuePosition) — tells "another game's queue" apart from "the
    /// same game under a different id".
    @Environment(GamesViewModel.self) var gamesViewModel
    @State private var controller = StreamController()
    @State private var showOverlay = false
    @State private var errorMessage: String?
    @State private var queueAttempt = 0
    @State private var queueStatus = ""
    @State private var queueStartedAt = Date()
    @State private var queuePosition: Int?
    @State private var queueEta: Int?
    /// Diagnostics for "some games never show a queue position" — see
    /// watchQueuePosition().
    @State private var queueDebug = ""
    /// Last result of the session/start "claim the machine" call.
    @State private var claimResult = ""
    /// Ensures the machine is claimed exactly once (the endpoint is rate-limited).
    @State private var didClaimMachine = false
    /// Host named by the claim response, if any — overrides the guessed one.
    @State private var claimedGateway: String?
    @State private var queueUpdatesSeen = 0
    @State private var seenAppIds: [Int] = []
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
                        // Always shown while connecting. Previously gated on
                        // queueAttempt > 0, which hid EVERYTHING whenever the
                        // poll loop was silently skipping (see the
                        // last-session mismatch note in BoosteroidClient) —
                        // leaving just "Connecting…" with no explanation.
                        VStack(spacing: 8) {
                            Group {
                                if let queuePosition {
                                    Text("Queue position: \(queuePosition)" + (queueEta.map { " — ~\($0)s" } ?? ""))
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                }
                                Text("Status: \(queueStatus.isEmpty ? "waiting" : queueStatus) — waited \(Int(Date().timeIntervalSince(queueStartedAt)))s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !queueDebug.isEmpty {
                                    Text(queueDebug)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if !claimResult.isEmpty {
                                    Text(claimResult)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 60)
                                }
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
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    Button("Leave Game") {
                        controller.disconnect()
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .foregroundStyle(.white)
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
            // Prefer the host the claim named over the one resolved from the
            // gateway list: that list is only the account's regional gateways,
            // not necessarily the machine actually assigned, and connecting to
            // the wrong one fails with "socket is not connected".
            var resolvedSession = session
            if let claimedGateway {
                resolvedSession.nodeBaseUrl = claimedGateway
            }
            await controller.connect(session: resolvedSession, settings: settings, cookies: cookies)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pulls the assigned host out of the claim response. The web client reads
    /// a `url` off that response, so look there first (and under `data`), then
    /// any gateway-ish field, then any boosteroid host anywhere in the body.
    /// Returns a scheme+host base URL, matching what `SessionInfo.nodeBaseUrl`
    /// expects.
    nonisolated static func gatewayFromClaim(_ body: String) -> String? {
        func baseURL(_ raw: String) -> String? {
            guard let comps = URLComponents(string: raw), let host = comps.host else { return nil }
            let scheme = comps.scheme ?? "https"
            if let port = comps.port { return "\(scheme)://\(host):\(port)" }
            return "\(scheme)://\(host)"
        }
        if let data = body.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scopes = [root, root["data"] as? [String: Any]].compactMap { $0 }
            for scope in scopes {
                for key in ["url", "gw", "gateway", "address", "host"] {
                    if let value = scope[key] as? String, let base = baseURL(value) { return base }
                }
            }
        }
        // Last resort: a bare host mentioned in the body.
        if let match = body.range(of: #"https?://[a-z0-9.\-]+\.boosteroid\.com(:\d+)?"#, options: .regularExpression) {
            return String(body[match])
        }
        return nil
    }

    /// Connects to Boosteroid's real-time WebSocket (see
    /// BoosteroidRealtimeClient) purely to surface a live numeric queue
    /// position/eta in the UI. Failure here is silent by design — this is
    /// cosmetic, not load-bearing; `start()`'s last-session polling is what
    /// actually decides when to proceed.
    private func watchQueuePosition() async {
        guard let (userId, token) = try? await authManager.resolveRealtimeCredentials() else { return }
        guard let targetAppId = Int(game.id) else {
            queueDebug = "game id '\(game.id)' isn't numeric — can't match queue pushes"
            return
        }
        for await event in await realtimeClient.connect(userId: userId, token: token) {
            if Task.isCancelled { break }
            switch event {
            case .queueUpdate(let appId, let position, let eta):
                queueUpdatesSeen += 1
                if !seenAppIds.contains(appId) { seenAppIds.append(appId) }

                if appId == targetAppId {
                    queuePosition = position
                    queueEta = eta
                    queueDebug = ""
                    continue
                }

                // CONFIRMED (see BoosteroidRealtimeClient): these pushes cover
                // every queue the account is in, including leftovers from games
                // launched earlier that keep counting down. If we're only
                // hearing about OTHER games, say so plainly — that other queue
                // is usually the one actually holding the account's slot, which
                // is why this game seems stuck with no position.
                if queuePosition == nil {
                    let others = seenAppIds
                        .filter { $0 != targetAppId }
                        .map { id in gamesViewModel.library.first { Int($0.id) == id }?.title ?? "app \(id)" }
                    if let other = others.last {
                        queueDebug = "No queue position reported for this game. You're also queued for \(other)" +
                            (position.map { " (position \($0))" } ?? "") + "."
                    }
                }
            case .queueReady(let appId, let sessionToken, let valueKeys):
                // The machine-is-ready signal. Claim ONCE — this reservation is
                // short-lived, but the endpoint is rate-limited (a retry loop
                // earned a 429), so exactly one call, mirroring the browser's
                // "INICIAR" button. `appId` may be absent in the push, in which
                // case it's for the game we're waiting on.
                // Do NOT call session/start here.
                //
                // CONFIRMED 2026-07-24 by driving a healthy session in the
                // browser and watching every request: the web client calls ONLY
                // enqueue, then goes straight to streaming — session/start is
                // never sent, the session reaches status "LI", and
                // session/details returns {queryString, gw} with gw a plain
                // STRING ("https://sp5.cloud.boosteroid.com:443").
                //
                // Our calling session/start is what produced the broken state:
                // the session went to "UN" and details then returned only
                // queryString, with no gw ever — i.e. no machine assigned. So
                // the ready signal is informational only; the host comes from
                // polling details for gw.
                _ = (sessionToken, valueKeys)
                guard !didClaimMachine, appId == nil || appId == targetAppId else { continue }
                didClaimMachine = true
                claimResult = "Machine ready — waiting for host…"
            case .raw, .closed, .failed:
                continue
            }
        }
    }
}
