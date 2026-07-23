import Foundation

// MARK: - Boosteroid Control WebSocket
//
// CONFIRMED 2026-07-23, THE root-cause fix for keyboard/mouse/controller
// input never working: this project previously assumed (carried over from
// CloudNow/GFN) that input rides a WebRTC data channel, and InputSender was
// built (and never even wired up — see StreamController) against that
// assumption. Live testing proved that wrong — a real session accepted
// clicks/keypresses from the browser, but this app's own RTCDataChannel
// prototype patch never saw a single byte cross any data channel. Reading
// Boosteroid's own `streaming.js` / `catch-events.js` bundles (fetched
// directly and read — the same technique that cracked the queue-position
// WebSocket earlier in this project) found the real mechanism: Boosteroid
// runs ALL input — keyboard, mouse, and gamepad — over a single dedicated
// JSON WebSocket, entirely separate from the WebRTC media path.
//
// CONFIRMED URL construction (`SessionHandler.wssHandler` in streaming.js):
//   wss://{nodeHost}/?{queryString}&x={width}&y={height}&lang={lang}
//     &refreshRate={rate}&rtcEngine=webrtc&clientType={web|native|controller}
//     &devType={desktop|mobile|tv|avtomotive|tablet}&os={win|lin|mac|a|atv|
//     webos|tizen|titan|vidaa|fireos}&rtcAudio=pcm
// - `nodeHost` is the SAME per-session gateway host as WebRTC signaling
//   (SessionInfo.nodeBaseUrl, e.g. "sp7.cloud.boosteroid.com:443").
// - `queryString` is EXACTLY `session/details`'s `data.queryString` JWT —
//   previously fetched and stored on SessionInfo but never used for
//   anything (see SessionInfo's doc comment, now corrected).
// - `clientType`/`devType`/`os` are enumerated IN THE SOURCE with values
//   that explicitly include native TV clients ("native"/"tv"/"atv") —
//   Boosteroid already anticipates non-browser Apple TV clients at the
//   protocol level, which is reassuring: this isn't fighting a browser-only
//   assumption, just filling in a client nobody had written yet.
//
// CONFIRMED message envelope: plain JSON TEXT frames (not binary), shape
// `{type, action, ...fields}`. For the four "external device" types
// (keyboard/mouse/controller/finger — CONFIRMED array literal in
// `SessionHandler.sendEvents`) the web client auto-appends an incrementing
// `id_cmd` and `from_udp: false` before sending; replicated in `send`
// below rather than requiring every call site to remember it.
//
// CONFIRMED per-type shapes (grep the git history / CLAUDE.md for the exact
// source snippets this was read from):
//   keyboard button:   {type:"keyboard", action:"button", isPressed, code}
//     `code` is a Windows Virtual-Key code — confirmed from the web
//     client's own stats-hotkey-release helper, which sends 0xA0-0xA3
//     (VK_LSHIFT..VK_RCONTROL). VideoSurfaceView's existing HID->VK table
//     (built for GFN) already produces exactly these VK values, unchanged.
//   mouse button:  {type:"mouse", action:"button", isPressed, btn}
//     (btn = standard DOM MouseEvent.button: 0 left, 1 middle, 2 right)
//   mouse wheel:   {type:"mouse", action:"wheel", deltaY: ±1}
//   mouse move:    {type:"mouse", movementX, movementY, surfaceWidth,
//     surfaceHeight, syncLocalPosition, movementIsAdjusted} — the real web
//     client ALSO supports absolute/locked-cursor modes with a lot of
//     adaptive normalization (see cursor-mode-manager.js, NOT ported here);
//     this client only implements the simpler pure-relative-movement path,
//     which is what a Bluetooth mouse/trackpad on tvOS produces anyway.
//   mouse connected (send once before the first move/button):
//     {type:"mouse", action:"connected", LeftBtnState:false,
//      MiddleBtnState:false, RightBtnState:false}
//   controller connected: {type:"controller", action:"connected",
//     name:"<gamepad vendor/product string><index>"} — the SERVER echoes
//     this back with an added `id` field; that `id` must be attached to
//     every subsequent button/axes/pad event for that controller (the web
//     client's `GamepadController.canSendInput` refuses to send without
//     one, so this client waits for the ack too rather than guessing).
//   controller disconnected: {type:"controller", action:"disconnected", id}
//   controller button: {type:"controller", action:"button", id, button,
//     value} — indices CONFIRMED from catch-events.js: 0=A 1=B 2=X 3=Y
//     4=LB 5=RB 6=Back 7=Start 8=LSclick 9=RSclick. LT/RT are NOT sent as
//     buttons — see axes 2/5 below.
//   controller axes: {type:"controller", action:"axes", id, axes, value}
//     — axes CONFIRMED: 0=LeftX 1=LeftY 2=LeftTrigger 3=RightX 4=RightY
//     5=RightTrigger. `value` is a SIGNED 16-bit range (±32767): sticks map
//     [-1,1] directly via round(x * 32767); triggers (naturally [0,1]) are
//     linearly remapped onto the SAME ±32767 range via
//     round(x * 32767 * 2) - 32767, i.e. an unpressed trigger reports
//     -32767, not 0.
//   controller pad (D-pad, sent as a hat rather than 4 buttons):
//     {type:"controller", action:"pad", id, hat} — TODO(protocol): only a
//     couple of hat values were confirmed from the source (e.g. up+left
//     produced 9); this client implements single-direction hats using a
//     standard 8-direction POV-hat numbering and leaves the exact
//     diagonal-combo encoding unconfirmed/approximate — a precision gap,
//     not a correctness one (basic D-pad presses should still register).
//   controller rumble (SERVER -> client): {type:"controller",
//     action:"rumble", id, left, right} — documented for completeness;
//     not wired to any vibration API on this client yet.
//
// NOT implemented: absolute/locked mouse cursor modes, and exact diagonal
// D-pad hat values — both precision/cosmetic gaps, see TODOs above and in
// InputSender, not correctness gaps.
actor BoosteroidControlChannel {
    enum IncomingEvent {
        case controllerAck(name: String, id: String)
        case controllerRumble(id: String, left: Double, right: Double)
        case raw(type: String?, action: String?)
        case closed
        case failed(String)
    }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)
    private var idCmdCounter: Int = 0
    private(set) var isOpen = false

    /// CONFIRMED array literal from `SessionHandler.sendEvents` — these four
    /// types get `id_cmd`/`from_udp` auto-appended; everything else (e.g.
    /// "settings"/"stream" housekeeping messages, not used by this client)
    /// does not.
    private static let externalDeviceTypes: Set<String> = ["keyboard", "mouse", "controller", "finger"]

    /// Opens the control WebSocket and returns a stream of parsed incoming
    /// events (mainly controller-connect acks). The stream finishes when the
    /// socket closes or errors.
    func connect(
        nodeBaseUrl: String,
        queryString: String,
        resolutionWidth: Int,
        resolutionHeight: Int,
        language: String = "en",
        refreshRate: Int = 60,
        os: String = "atv",
        devType: String = "tv",
        clientType: String = "native"
    ) -> AsyncStream<IncomingEvent> {
        let host = nodeBaseUrl
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        var urlString = "wss://\(host)/?\(queryString)"
        urlString += "&x=\(resolutionWidth)&y=\(resolutionHeight)"
        urlString += "&lang=\(language)&refreshRate=\(refreshRate)"
        urlString += "&rtcEngine=webrtc&clientType=\(clientType)&devType=\(devType)&os=\(os)&rtcAudio=pcm"

        guard let url = URL(string: urlString) else {
            return AsyncStream { $0.finish() }
        }

        let wsTask = session.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        isOpen = true

        return AsyncStream { continuation in
            let loopTask = Task { [weak self] in
                await self?.receiveLoop(task: wsTask, continuation: continuation)
            }
            continuation.onTermination = { _ in
                loopTask.cancel()
                wsTask.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    func disconnect() {
        isOpen = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    /// Sends one input/control event. `type`/`action`/`fields` build the
    /// same `{type, action, ...}` shape the real web client sends — see this
    /// file's header for the confirmed per-type field names. `id_cmd`/
    /// `from_udp` are appended automatically for the four external-device
    /// types, matching `SessionHandler.sendEvents`.
    func send(type: String, action: String? = nil, fields: [String: Any] = [:]) async {
        guard isOpen, let task else { return }
        var data: [String: Any] = ["type": type]
        if let action { data["action"] = action }
        for (key, value) in fields { data[key] = value }
        if Self.externalDeviceTypes.contains(type) {
            idCmdCounter += 1
            data["id_cmd"] = idCmdCounter
            data["from_udp"] = false
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let text = String(data: jsonData, encoding: .utf8) else { return }
        try? await task.send(.string(text))
    }

    // MARK: - Private

    private func receiveLoop(task: URLSessionWebSocketTask, continuation: AsyncStream<IncomingEvent>.Continuation) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    Self.handle(text: text, continuation: continuation)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        Self.handle(text: text, continuation: continuation)
                    }
                @unknown default:
                    break
                }
            } catch {
                if let wsError = error as? URLError, wsError.code == .cancelled { break }
                continuation.yield(.failed(error.localizedDescription))
                break
            }
        }
        isOpen = false
        continuation.yield(.closed)
        continuation.finish()
    }

    /// CONFIRMED from streaming.js's `controlWebsocket.onmessage` switch on
    /// `message.type` — the same `{type, action, ...}` envelope as outgoing
    /// messages. For `type:"controller", action:"connected"` the server
    /// echoes back the client's own `name` with an added `id` — that's the
    /// controller-connect handshake ack InputSender waits for.
    private static func handle(text: String, continuation: AsyncStream<IncomingEvent>.Continuation) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let type = obj["type"] as? String
        let action = obj["action"] as? String

        if type == "controller", action == "connected",
           let name = obj["name"] as? String, let id = Self.stringValue(obj["id"]) {
            continuation.yield(.controllerAck(name: name, id: id))
            return
        }
        if type == "controller", action == "rumble", let id = Self.stringValue(obj["id"]) {
            continuation.yield(.controllerRumble(
                id: id,
                left: (obj["left"] as? Double) ?? 0,
                right: (obj["right"] as? Double) ?? 0
            ))
            return
        }
        continuation.yield(.raw(type: type, action: action))
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(d) }
        return nil
    }
}
