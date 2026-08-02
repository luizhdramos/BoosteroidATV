import SwiftUI
import UIKit

/// Windows Virtual-Key codes — shared by the top-bar overlay (Steam Overlay
/// hotkey) and VirtualKeyboardView. Keys are sent as Windows VK codes over
/// the WebRTC data channel regardless of source (hardware keyboard, on-screen
/// keyboard, or a synthesized combo like Shift+Tab) — see InputSender and
/// VideoSurfaceView's HID→VK table.
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
    // Standard Win32 OEM punctuation VK codes (winuser.h) — unlike letters
    // and digits, these don't line up with their ASCII/unicode values, so
    // VirtualKeyboardView can't derive them from the key's own character.
    static let backtick: UInt16 = 0xC0
    static let minus: UInt16 = 0xBD
    static let equals: UInt16 = 0xBB
    static let leftBracket: UInt16 = 0xDB
    static let rightBracket: UInt16 = 0xDD
    static let backslash: UInt16 = 0xDC
    static let semicolon: UInt16 = 0xBA
    static let quote: UInt16 = 0xDE
    static let comma: UInt16 = 0xBC
    static let period: UInt16 = 0xBE
    static let slash: UInt16 = 0xBF
}

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
    @State private var showKeyboard = false
    /// The "More Options" pill's dropdown panel (Back to Menu / Performance
    /// Overlay / Stream Details), nested under the main top bar.
    @State private var showMoreOptions = false
    /// The "Performance Overlay" row's own flyout (Enable/Disable), opening
    /// to the left of the More Options panel — a nested submenu, not an
    /// inline toggle.
    @State private var showPerformanceFlyout = false
    /// nil = follow the session's saved Settings value; set once the user
    /// flips it from the in-stream Performance Overlay toggle, for the rest
    /// of this session only (not persisted — Settings remains the default).
    @State private var statsOverlayOverride: Bool?
    /// Set by "Back to Menu": leave the session running and just navigate
    /// back Home, instead of tearing the connection down the way the
    /// explicit Disconnect button does — see the .onDisappear note below.
    @State private var leaveWithoutDisconnecting = false
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
                    VStack(spacing: 32) {
                        Text(game.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)

                        // Commercial-style progress timeline: Queue -> Machine
                        // Found -> Preparing/Ready, filling with the brand's
                        // purple gradient (same as the bolt logo) as each
                        // stage completes, instead of a generic spinner.
                        sessionTimeline
                            .frame(maxWidth: 720)
                            .animation(.easeInOut(duration: 0.4), value: currentStageIndex)

                        Text(timelineDetail)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 60)

                        Button("Cancel") { onDismiss() }
                            .buttonStyle(.bordered)
                            .tint(.gray)
                    }
                }
            case .streaming:
                VideoSurfaceViewRepresentable(
                    streamController: controller,
                    // Focus must reach SwiftUI whenever an overlay is up, or the
                    // on-screen keyboard's keys can't be selected.
                    showOverlay: showOverlay || showKeyboard,
                    // Only ever OPENS the bar. Closing/collapsing is owned
                    // exclusively by the root .onExitCommand below — once the
                    // bar is up, focus has moved from this raw UIKit view to
                    // a SwiftUI button, so a second Menu press is delivered
                    // through SwiftUI's focus system, not here.
                    onMenu: { showOverlay = true },
                    pointerMode: pointerMode,
                    onPointerPosition: { localCursor = $0 },
                    // Pointer coordinates are in the REMOTE desktop's pixels, so
                    // use the live decoded size once it's known and fall back to
                    // the requested resolution before the first frame arrives.
                    surfaceSize: controller.stats.resolutionWidth > 0
                        ? CGSize(width: controller.stats.resolutionWidth,
                                 height: controller.stats.resolutionHeight)
                        : StreamView.parseResolution(settings.resolution)
                )
                .ignoresSafeArea()
                // Compact performance overlay — only when enabled (Settings'
                // saved value, unless overridden live from the More Options panel).
                if showStats {
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
                    // Bottom-center, not floating mid-screen — matches the
                    // reference design and keeps it clear of the game's own
                    // center-screen UI.
                    VStack {
                        Spacer()
                        VirtualKeyboardView(
                            inputHandler: controller.inputSender,
                            onClose: { showKeyboard = false }
                        )
                        .padding(.bottom, 48)
                    }
                } else if showOverlay {
                    topBarOverlay
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
            // "Back to Menu" leaves the session alone (see leaveWithoutDisconnecting);
            // every other way this view goes away — Disconnect, an error's
            // Close button, a failed/disconnected status screen — tears the
            // local connection down as before.
            if !leaveWithoutDisconnecting {
                controller.disconnect()
            }
        }
        // Mounted unconditionally (not nested inside topBarOverlay) so it's
        // active from the very first frame. On tvOS a presented
        // fullScreenCover dismisses itself on the Menu button by default
        // unless something handles onExitCommand — nesting it only inside
        // the overlay left a gap where the very first Menu press (before
        // the overlay existed) fell through to that default dismiss AT THE
        // SAME TIME our own onMenu handler was opening the bar, which is why
        // pressing back both showed the menu AND bounced back to Home.
        .onExitCommand {
            switch controller.state {
            case .streaming:
                if showKeyboard {
                    showKeyboard = false
                } else if showPerformanceFlyout {
                    showPerformanceFlyout = false
                } else if showMoreOptions {
                    showMoreOptions = false
                } else {
                    showOverlay.toggle()
                }
            default:
                // Queue/connect screen: Menu acts as Cancel, same as the
                // Cancel button, instead of doing nothing.
                onDismiss()
            }
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
        }
        .ignoresSafeArea()
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
        var line = "Bitrate: \(String(format: "%.1f", mbps)) Mbps | Stream FPS: \(controller.streamFps) | Latency: \(controller.rttMs)ms"
        // Video and input ride entirely separate connections — the control
        // channel can silently die (network blip, server timeout) while video
        // keeps playing perfectly, leaving mouse/keyboard/controller dead with
        // no other visible sign. Surfaced here so it's caught even when
        // pointer mode is off. See controlChannelAlive's doc comment.
        if !controller.controlChannelAlive { line += " | INPUT CHANNEL DEAD" }
        return VStack {
            HStack {
                Text(line)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(controller.controlChannelAlive ? .white.opacity(0.9) : .red)
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

    // MARK: In-Stream Top Bar
    //
    // Design: a slim HUD bar pinned to the top of the screen (game still
    // visible underneath), not a full-screen pause modal — Disconnect on the
    // left, Keyboard / Pointer / Steam Overlay / More Options on the right.
    // The Menu/back remote button opens it; pressing Menu again collapses it
    // (the More Options panel, if open, collapses first) — see the root
    // .onExitCommand in body, which owns all of that closing/collapsing
    // logic so it's active from the very first frame.

    private var showStats: Bool { statsOverlayOverride ?? settings.showStatsOverlay }

    private var topBarOverlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Button {
                    controller.disconnect()
                    onDismiss()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.gray)

                Spacer()

                HStack(spacing: 14) {
                    topBarPill("Keyboard", systemImage: "keyboard") {
                        showOverlay = false
                        showKeyboard = true
                    }
                    topBarPill("Pointer", systemImage: pointerMode ? "cursorarrow.click.2" : "cursorarrow",
                               active: pointerMode) {
                        pointerMode.toggle()
                        showOverlay = false
                    }
                    // Sends Shift+Tab — the standard Steam in-game-overlay
                    // hotkey — straight to the remote machine, then hands
                    // input back to the video surface immediately: Steam's
                    // overlay renders inside the stream itself, so it needs
                    // direct remote input from here on, not this app's menu.
                    topBarPill("Steam Overlay", systemImage: "square.stack") {
                        sendSteamOverlayHotkey()
                        showOverlay = false
                    }
                    topBarPill("More Options", systemImage: "ellipsis.circle", active: showMoreOptions) {
                        showMoreOptions.toggle()
                        if !showMoreOptions { showPerformanceFlyout = false }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 16)
            // Without an explicit width, this HStack (and therefore the
            // background below, which follows its host's size) only sized
            // itself to fit its content instead of the full screen — which
            // is why the bar looked like it stopped short of the edges.
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.92), .black.opacity(0.75), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 170)
                .ignoresSafeArea(edges: .top),
                alignment: .top
            )

            if showMoreOptions {
                HStack(alignment: .top, spacing: 12) {
                    Spacer()
                    // Opens to the LEFT of the main panel (matches the
                    // reference design) — listed first in this HStack, with
                    // the main panel pinned to the trailing edge after it.
                    if showPerformanceFlyout {
                        performanceOverlayFlyout
                    }
                    moreOptionsPanel
                }
                .padding(.trailing, 32)
                .padding(.top, 8)
            }

            Spacer()
        }
        // Closing/collapsing is handled by the root .onExitCommand (see
        // body) — it needs to be mounted unconditionally, not nested here,
        // or the very first Menu press (before this view exists) falls
        // through to the system's default "dismiss the fullScreenCover"
        // instead of our own logic.
    }

    @ViewBuilder
    private func topBarPill(_ title: String, systemImage: String, active: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        // Manually white when "on" (matches SettingsView's OptionRow
        // convention for a persistent selected state), gray otherwise — tvOS
        // still auto-inverts to white-on-dark on focus on top of this.
        .tint(active ? .white : .gray)
    }

    /// A smaller, fixed font for the More Options / flyout rows — the
    /// system's default tvOS button text is large enough that, combined
    /// with an icon and a chevron, "Performance Overlay" wrapped down to one
    /// character per line inside the panel's width. Sizing text explicitly
    /// (rather than relying on the default) keeps these compact HUD rows on
    /// one line.
    private static let panelRowFont: Font = .system(size: 24, weight: .medium)

    /// "Back to Menu" / "Performance Overlay" (opens its own Enable/Disable
    /// flyout to the left — see performanceOverlayFlyout) / "Stream Details"
    /// (placeholder — content still TBD).
    private var moreOptionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Goes back to the Home/games screen WITHOUT disconnecting —
            // unlike the top-left Disconnect pill, which tears the
            // connection down. See leaveWithoutDisconnecting's use in
            // .onDisappear.
            Button {
                leaveWithoutDisconnecting = true
                onDismiss()
            } label: {
                Label("Back to Menu", systemImage: "chevron.left")
                    .font(Self.panelRowFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.gray)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().background(.white.opacity(0.15)).padding(.horizontal, 12)

            Button {
                showPerformanceFlyout.toggle()
            } label: {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                    Text("Performance Overlay")
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .font(Self.panelRowFont)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(showPerformanceFlyout ? .white : .gray)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Button {
                // Stream Details: intentionally empty for now — content TBD.
            } label: {
                Label("Stream Details", systemImage: "chart.bar")
                    .font(Self.panelRowFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.gray)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 420)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The Performance Overlay row's own nested submenu (Enable/Disable),
    /// a proper cascading flyout rather than inline buttons — matches the
    /// reference design, which pops this out to the left of the main panel.
    private var performanceOverlayFlyout: some View {
        VStack(alignment: .leading, spacing: 4) {
            performanceFlyoutRow("Enable", selected: showStats) { statsOverlayOverride = true }
            performanceFlyoutRow("Disable", selected: !showStats) { statsOverlayOverride = false }
        }
        .padding(.vertical, 8)
        .frame(width: 260)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func performanceFlyoutRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if selected {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
            .font(Self.panelRowFont)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(.gray)
        .padding(.horizontal, 8)
    }

    /// Standard Steam in-game-overlay hotkey (Shift+Tab): a real key-down for
    /// Shift, then Tab with the shift modifier bit set, released in reverse
    /// order — mirrors how a real keyboard combo arrives, unlike just setting
    /// the modifier bit on a lone Tab event (see VideoSurfaceView's HID→VK
    /// path and InputSender.sendKeyEvent).
    private func sendSteamOverlayHotkey() {
        let shiftHeld: UInt16 = 0x0001
        controller.inputSender?.sendKeyEvent(down: true, vk: VK.shift, scancode: 0, modifiers: shiftHeld)
        controller.inputSender?.sendKeyEvent(down: true, vk: VK.tab, scancode: 0, modifiers: shiftHeld)
        controller.inputSender?.sendKeyEvent(down: false, vk: VK.tab, scancode: 0, modifiers: shiftHeld)
        controller.inputSender?.sendKeyEvent(down: false, vk: VK.shift, scancode: 0, modifiers: 0)
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

    // MARK: Loading Timeline

    /// Coarse progress for the loading timeline: 0 = still queued, 1 = a
    /// machine has been matched/claimed, 2 = WebRTC is actively negotiating
    /// (StreamController.stage becomes non-empty once controller.connect()
    /// starts — see StreamController.swift).
    private var currentStageIndex: Int {
        if !controller.stage.isEmpty { return 2 }
        if queueStatus == "LI" || didClaimMachine { return 1 }
        return 0
    }

    /// CONFIRMED stage ordering (StreamController.swift): "Offer accepted —
    /// waiting for video…" is the last stage string before frames actually
    /// arrive and state flips to .streaming — treat it as "done preparing".
    private var isPreparingFinished: Bool {
        controller.stage.contains("Offer accepted")
    }

    private var timelineDetail: String {
        switch currentStageIndex {
        case 0:
            if let queuePosition {
                return "Queue position: \(queuePosition)" + (queueEta.map { " — ~\($0)s" } ?? "")
            }
            return "Waiting in queue…"
        case 1:
            return "Machine found — confirming session…"
        default:
            if isPreparingFinished {
                return "Machine ready — loading the game…"
            }
            return controller.stage.isEmpty ? "Preparing the machine…" : controller.stage
        }
    }

    private var sessionTimeline: some View {
        let index = currentStageIndex
        let labels = ["Queue", "Machine Found", isPreparingFinished ? "Machine Ready" : "Preparing Machine"]
        return HStack(alignment: .top, spacing: 0) {
            ForEach(labels.indices, id: \.self) { i in
                timelineNode(label: labels[i], reached: i <= index, active: i == index)
                if i < labels.count - 1 {
                    timelineConnector(filled: i < index)
                }
            }
        }
    }

    @ViewBuilder
    private func timelineNode(label: String, reached: Bool, active: Bool) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(reached ? AnyShapeStyle(BoosteroidTheme.brandGradient) : AnyShapeStyle(Color.white.opacity(0.15)))
                    .frame(width: 22, height: 22)
                if active {
                    Circle()
                        .stroke(BoosteroidTheme.brandGradient, lineWidth: 2)
                        .frame(width: 32, height: 32)
                } else if reached {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(reached ? .white : .secondary)
                .multilineTextAlignment(.center)
                .frame(width: 130)
        }
    }

    @ViewBuilder
    private func timelineConnector(filled: Bool) -> some View {
        Rectangle()
            .fill(filled ? AnyShapeStyle(BoosteroidTheme.brandGradient) : AnyShapeStyle(Color.white.opacity(0.15)))
            .frame(height: 3)
            .frame(maxWidth: .infinity)
            .padding(.top, 11) // centers on the 22pt circle above
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

    // Uses the file-scope VK enum (Windows Virtual-Key codes) defined above.

    private let topRow: [String] = ["1","2","3","4","5","6","7","8","9","0"]
    private let qwertyRow: [String] = ["Q","W","E","R","T","Y","U","I","O","P"]
    private let homeRow: [String] = ["A","S","D","F","G","H","J","K","L"]
    private let bottomRow: [String] = ["Z","X","C","V","B","N","M"]

    // Full QWERTY layout (numbers/punctuation included, real key placement)
    // per the reference design, rather than the old letters-only + a
    // separate function-key row. Sized down considerably from the first
    // pass (52pt keys, tighter spacing, explicit small font) — the default
    // tvOS button size/font made every key noticeably larger than the
    // reference image.
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                keyButton("`") { send(vk: VK.backtick) }
                ForEach(topRow, id: \.self) { key in
                    keyButton(key) { send(vk: UInt16(key.unicodeScalars.first!.value)) }
                }
                keyButton("-") { send(vk: VK.minus) }
                keyButton("=") { send(vk: VK.equals) }
                keyButton("Backspace", width: 100, tint: .red) { send(vk: VK.back) }
            }
            HStack(spacing: 6) {
                keyButton("Tab", width: 72) { send(vk: VK.tab) }
                ForEach(qwertyRow, id: \.self) { key in
                    keyButton(shifted ? key : key.lowercased()) {
                        send(vk: UInt16(key.unicodeScalars.first!.value))
                    }
                }
                keyButton("[") { send(vk: VK.leftBracket) }
                keyButton("]") { send(vk: VK.rightBracket) }
                keyButton("\\") { send(vk: VK.backslash) }
            }
            HStack(spacing: 6) {
                ForEach(homeRow, id: \.self) { key in
                    keyButton(shifted ? key : key.lowercased()) {
                        send(vk: UInt16(key.unicodeScalars.first!.value))
                    }
                }
                keyButton(";") { send(vk: VK.semicolon) }
                keyButton("'") { send(vk: VK.quote) }
                keyButton("Enter", width: 100) { send(vk: VK.enter) }
            }
            HStack(spacing: 6) {
                keyButton(shifted ? "Shift ON" : "Shift", width: 88) { shifted.toggle() }
                ForEach(bottomRow, id: \.self) { key in
                    keyButton(shifted ? key : key.lowercased()) {
                        send(vk: UInt16(key.unicodeScalars.first!.value))
                    }
                }
                keyButton(",") { send(vk: VK.comma) }
                keyButton(".") { send(vk: VK.period) }
                keyButton("/") { send(vk: VK.slash) }
            }
            HStack(spacing: 6) {
                keyButton("Esc") { send(vk: VK.escape) }
                keyButton("Space", width: 260) { send(vk: VK.space) }
                keyButton("←") { send(vk: VK.left) }
                keyButton("↑") { send(vk: VK.up) }
                keyButton("↓") { send(vk: VK.down) }
                keyButton("→") { send(vk: VK.right) }
                keyButton("Close", width: 72, tint: .red) { onClose() }
            }
        }
        .padding(16)
        // Restored an opaque enclosing panel: each key's own .bordered fill
        // is translucent by design (so it can invert on focus), which read
        // as "too transparent" sitting directly over bright game content.
        // Sitting on a solid dark backdrop instead makes the same keys read
        // as solid/legible, matching the reference image.
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func keyButton(_ label: String, width: CGFloat = 52, tint: Color = .gray,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .medium))
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .frame(minWidth: width, minHeight: 40)
    }

    /// Tap = press and release. `shifted` is reported as the modifier bit the
    /// hardware-keyboard path uses, so capitals and symbols behave the same way.
    private func send(vk: UInt16) {
        let modifiers: UInt16 = shifted ? 0x0001 : 0
        inputHandler?.sendKeyEvent(down: true, vk: vk, scancode: 0, modifiers: modifiers)
        inputHandler?.sendKeyEvent(down: false, vk: vk, scancode: 0, modifiers: modifiers)
    }
}
