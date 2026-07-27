import SwiftUI
import UIKit

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
    /// Siri Remote touch surface acts as a mouse (see VideoSurfaceView).
    @State private var pointerMode = false
    /// Tracked pointer position in REMOTE-desktop pixels. Kept in step with the
    /// real cursor because pointer mode pins it to (0,0) when switched on.
    @State private var localCursor: CGPoint = .zero
    /// Clicks the tap recognizer actually saw — proves whether the press is
    /// reaching us at all, separately from the server acting on it.
    @State private var pointerClicks = 0
    @State private var showKeyboard = false
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
    /// One shared client so the queues/start token can redirect the readiness
    /// polling that start() is already running (see setPreferredSessionId).
    @State private var client = BoosteroidClient()

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
                VideoSurfaceViewRepresentable(
                    streamController: controller,
                    // Focus must reach SwiftUI whenever an overlay is up, or the
                    // on-screen keyboard's keys can't be selected.
                    showOverlay: showOverlay || showKeyboard,
                    onMenu: { showOverlay.toggle() },
                    pointerMode: pointerMode,
                    onPointerPosition: { localCursor = $0 },
                    // Pointer coordinates are in the REMOTE desktop's pixels, so
                    // use the live decoded size once it's known and fall back to
                    // the requested resolution before the first frame arrives.
                    surfaceSize: controller.stats.resolutionWidth > 0
                        ? CGSize(width: controller.stats.resolutionWidth,
                                 height: controller.stats.resolutionHeight)
                        : StreamView.parseResolution(settings.resolution),
                    onPointerClicked: { pointerClicks += 1 }
                )
                .ignoresSafeArea()
                // Compact performance overlay — only when enabled in Settings.
                if settings.showStatsOverlay {
                    statsOverlay
                }
                // The remote desktop's pointer isn't drawn into the video, so
                // without this pointer mode moved an invisible cursor. Prefer
                // the server's reported position; fall back to tracking our own
                // movement locally (approximate, but better than nothing).
                if pointerMode {
                    pointerCursor
                }
                if showKeyboard {
                    VirtualKeyboardView(
                        inputHandler: controller.inputSender,
                        onClose: { showKeyboard = false }
                    )
                    .padding(40)
                } else if showOverlay {
                    overlay
                }
            case .disconnected(let reason):
                statusView(title: "Disconnected", message: reason)
            case .failed(let message):
                statusView(title: "Stream Failed", message: message)
            }
        }
        .task { await start() }
        // Keep the Apple TV awake for the WHOLE session, queue included.
        // Otherwise the screen saver kicks in while waiting and the device can
        // sleep, suspending the app — which drops the control/realtime sockets
        // and loses the machine-ready window (tvOS gives no background
        // execution, so a suspended app cannot hold a queue).
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.disconnect()
        }
    }

    /// A drawn pointer for pointer mode.
    ///
    /// Boosteroid does NOT composite the remote cursor into the video (its web
    /// client draws it from separate updates — see the `.cursor` note in
    /// BoosteroidControlChannel), so nothing was visible at all. If the server
    /// reports a position we place the pointer there, scaled from remote-desktop
    /// pixels; otherwise it follows our own dead-reckoning of the movement we've
    /// sent, which can drift and is only a stopgap.
    private var pointerCursor: some View {
        GeometryReader { geo in
            let remote = CGSize(
                width: max(1, CGFloat(controller.stats.resolutionWidth)),
                height: max(1, CGFloat(controller.stats.resolutionHeight))
            )
            // Both sources are in remote-desktop pixels now: the server's when it
            // reports one, otherwise our own tracking, which is trustworthy
            // because pointer mode pins the cursor to (0,0) on activation.
            let source = controller.serverCursor ?? localCursor
            let point = CGPoint(x: source.x / remote.width * geo.size.width,
                                y: source.y / remote.height * geo.size.height)
            // Drawn as a shape rather than an SF Symbol: "cursorarrow.fill"
            // isn't available on tvOS, and Image(systemName:) renders NOTHING
            // for an unknown name — which is why the pointer vanished entirely.
            // A path can't go missing.
            PointerArrow()
                .fill(.white)
                .overlay(PointerArrow().stroke(.black.opacity(0.85), lineWidth: 1.5))
                .frame(width: 16, height: 24)
                // The tip is the click point, so offset the shape's centre.
                .position(x: min(max(point.x, 0), geo.size.width) + 8,
                          y: min(max(point.y, 0), geo.size.height) + 12)

            // Says whether the drawn arrow reflects the REAL remote cursor or
            // only our own dead-reckoning. It matters: with dead-reckoning the
            // arrow can sit somewhere the remote pointer isn't, so a click that
            // "does nothing" may simply have landed elsewhere.
            Text((controller.serverCursor == nil
                  ? "pointer: estimated (server sends no position\(controller.cursorFields.isEmpty ? "" : "; fields: \(controller.cursorFields.joined(separator: ","))"))"
                  : "pointer: server-tracked")
                 + " · clicks sent: \(pointerClicks)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .padding(6)
                .background(.black.opacity(0.4), in: Capsule())
                .position(x: geo.size.width / 2, y: geo.size.height - 40)
        }
        .allowsHitTesting(false)
    }

    /// "1920x1080" → CGSize, for the pre-first-frame fallback above.
    static func parseResolution(_ resolution: String) -> CGSize {
        let parts = resolution.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else {
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(width: w, height: h)
    }

    /// A classic arrow cursor, drawn as a path so it can't depend on an SF
    /// Symbol name being available. Its tip sits at (0,0) of the frame.
    private struct PointerArrow: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let w = rect.width, h = rect.height
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: h * 0.78))
            path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.60))
            path.addLine(to: CGPoint(x: w * 0.46, y: h))
            path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.90))
            path.addLine(to: CGPoint(x: w * 0.50, y: h * 0.52))
            path.addLine(to: CGPoint(x: w, y: h * 0.50))
            path.closeSubpath()
            return path
        }
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
                    // Typing and pointing are the two things a gamepad can't do
                    // — needed for launchers, logins and in-game search.
                    Button("Keyboard") {
                        showOverlay = false
                        showKeyboard = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                    Button(pointerMode ? "Pointer: On" : "Pointer: Off") {
                        pointerMode.toggle()
                        showOverlay = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(pointerMode ? .green : .gray)
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

    /// Pulls a session id out of the confirmation's 201 body. Looks at the
    /// likely field names (top level and under `data`), then falls back to any
    /// bare UUID in the body.
    nonisolated static func sessionIdFromConfirm(_ body: String) -> String? {
        if let data = body.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scopes = [root, root["data"] as? [String: Any]].compactMap { $0 }
            for scope in scopes {
                for key in ["sessionId", "session_id", "id", "sessionToken", "token"] {
                    if let value = scope[key] as? String, value.count >= 32 { return value }
                }
            }
        }
        let uuid = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        return body.range(of: uuid, options: .regularExpression).map { String(body[$0]) }
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
                // CONFIRMED: the confirmation's 201 body carries
                // `gateways: [{address, …}]`. Prefer an entry flagged priority /
                // active, else the first one.
                if let gateways = scope["gateways"] as? [[String: Any]], !gateways.isEmpty {
                    let preferred = gateways.first { ($0["priority"] as? Bool) == true }
                        ?? gateways.first { ($0["active"] as? Bool) == true }
                        ?? gateways[0]
                    if let address = preferred["address"] as? String, let base = baseURL(address) { return base }
                }
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
                // CONFIRMED 2026-07-24, both paths observed live:
                //
                // * NO QUEUE: enqueue alone is enough — the session goes to "LI"
                //   and details returns gw. session/start is never sent.
                // * AFTER A QUEUE (this branch): the machine is only RESERVED.
                //   The web client shows "machine found / INICIAR" and that
                //   button POSTs session/start. Watched in the browser: right
                //   after it, status is "UN" with no gw for a few seconds, then
                //   flips to "LI" with gw (e.g. sp6). Without that call the
                //   reservation just sits there — which is this app's
                //   "Machine ready — waiting for host…" hang.
                //
                // So the claim IS required here. An earlier pass removed it
                // after seeing only the no-queue path; that was wrong.
                guard !didClaimMachine, appId == nil || appId == targetAppId else { continue }
                didClaimMachine = true
                claimResult = "Machine ready — confirming…"
                guard let cookies = try? await authManager.resolveCookies() else { continue }

                // The token IS the real session's id. last-session keeps
                // reporting a stale one, so redirect readiness polling here or
                // we'd wait forever on a session that will never get a machine.
                if let sessionToken {
                    await client.setPreferredSessionId(sessionToken)
                }

                let result = await client.startStreamingSession(
                    appId: targetAppId, sessionToken: sessionToken, cookies: cookies
                )
                // Report the token/fields either way: the exact spelling of the
                // token field in this push still hasn't been captured, and a
                // claim can return 2xx while the machine never gets assigned.
                let tokenNote = sessionToken == nil
                    ? "no token (fields: [\(valueKeys.joined(separator: ","))])"
                    : "token ok"
                if (200...299).contains(result.status) {
                    // 201 Created means the server made something and described
                    // it in the body. Polling the token alone still timed out,
                    // so prefer any session id / gateway named here, and show
                    // the body either way so its shape stops being a guess.
                    if let created = Self.sessionIdFromConfirm(result.body) {
                        await client.setPreferredSessionId(created)
                    }
                    if let host = Self.gatewayFromClaim(result.body) {
                        claimedGateway = host
                        // Tell the waiting loop too: with the host known, a
                        // details response carrying only queryString is enough
                        // to proceed (no `gw` is ever sent while status is UN).
                        await client.setPreferredGateway(host)
                    }
                    claimResult = "Confirmed (\(result.status)) — "
                        + (claimedGateway.map { "host \($0)" } ?? "NO host parsed: \(result.body.prefix(120))")
                } else {
                    claimResult = "Confirm failed (\(result.status), \(tokenNote)): \(result.body.prefix(70))"
                }
            case .raw, .closed, .failed:
                continue
            }
        }
    }
}

/// An on-screen keyboard for typing into the streamed game — logging into a
/// launcher, searching, entering a name — none of which a gamepad can do.
///
/// Keys are sent straight through `InputEventHandler.sendKeyEvent` as Windows
/// Virtual-Key codes, the same encoding the hardware-keyboard path already uses
/// (see VideoSurfaceView's HID→VK table and BoosteroidControlChannel's
/// `keyboard/button` note). Each tap sends a down followed by an up, since the
/// remote gives no press-and-hold semantics here.
struct VirtualKeyboardView: View {
    /// Where the key events go. Weakly held by the caller's InputSender.
    let inputHandler: InputEventHandler?
    let onClose: () -> Void

    @State private var shifted = false

    // Windows Virtual-Key codes.
    private enum VK {
        static let back: UInt16 = 0x08
        static let tab: UInt16 = 0x09
        static let enter: UInt16 = 0x0D
        static let shift: UInt16 = 0x10
        static let escape: UInt16 = 0x1B
        static let space: UInt16 = 0x20
        static let left: UInt16 = 0x25
        static let up: UInt16 = 0x26
        static let right: UInt16 = 0x27
        static let down: UInt16 = 0x28
    }

    private let rows: [[String]] = [
        ["1","2","3","4","5","6","7","8","9","0"],
        ["Q","W","E","R","T","Y","U","I","O","P"],
        ["A","S","D","F","G","H","J","K","L"],
        ["Z","X","C","V","B","N","M"],
    ]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { key in
                        keyButton(shifted ? key : key.lowercased()) {
                            send(vk: UInt16(key.unicodeScalars.first!.value))
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                keyButton(shifted ? "Shift ON" : "Shift", wide: true) { shifted.toggle() }
                keyButton("Space", wide: true) { send(vk: VK.space) }
                keyButton("Enter", wide: true) { send(vk: VK.enter) }
                keyButton("Back", wide: true) { send(vk: VK.back) }
            }
            HStack(spacing: 10) {
                keyButton("Esc") { send(vk: VK.escape) }
                keyButton("Tab") { send(vk: VK.tab) }
                keyButton("←") { send(vk: VK.left) }
                keyButton("↑") { send(vk: VK.up) }
                keyButton("↓") { send(vk: VK.down) }
                keyButton("→") { send(vk: VK.right) }
                keyButton("Close", wide: true, tint: .red) { onClose() }
            }
        }
        .padding(28)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func keyButton(_ label: String, wide: Bool = false, tint: Color = .gray,
                           action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .tint(tint)
            .frame(minWidth: wide ? 150 : 70)
    }

    /// Tap = press and release. `shifted` is reported as the modifier bit the
    /// hardware-keyboard path uses, so capitals and symbols behave the same way.
    private func send(vk: UInt16) {
        let modifiers: UInt16 = shifted ? 0x0001 : 0
        inputHandler?.sendKeyEvent(down: true, vk: vk, scancode: 0, modifiers: modifiers)
        inputHandler?.sendKeyEvent(down: false, vk: vk, scancode: 0, modifiers: modifiers)
    }
}
