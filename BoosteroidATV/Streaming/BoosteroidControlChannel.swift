import Foundation

// MARK: - Boosteroid Control WebSocket
//
// CONFIRMED 2026-07-23 via live testing + reading Boosteroid's own
// `streaming.js`/`catch-events.js`/`webrtcstreamer.js` bundles. This socket
// is the PRIMARY control plane for a streaming session — far more than an
// "input channel":
//
//   1. Opening it CLAIMS THE SESSION FOR THIS DEVICE. Doing so triggers a
//      "switch device" server-side — CONFIRMED by a live test: opening a
//      second control socket (with clientType=native) against a session that
//      was actively streaming in a browser instantly kicked the browser to a
//      "you just switched your session to another device" screen. This is
//      why the tvOS app, before it opened this socket at all, could only ever
//      get video by piggybacking a session a browser had already claimed —
//      and why opening it at the WRONG time (after WebRTC negotiation, as a
//      first buggy pass did) black-screened everything.
//   2. Once open, the server PUSHES session config on it: `settings/udpforward`
//      (raw-UDP transport ports, unused by the WebRTC path), `settings/streamIds`
//      (resolution), and a `stream/*` burst (`bitrate`, `framerate`, `key`).
//   3. It GATES WebRTC: the web client starts its WebRTC engine
//      (`WebRtcTransport.connect()` → getIceServers/call/ICE) ONLY from the
//      handler for a `{"type":"settings","action":"webrtc"}` message pushed
//      on THIS socket. So the correct order is: open this socket FIRST, wait
//      for `settings/webrtc`, THEN do WebRTC signaling. StreamController now
//      follows exactly that order (see its connect()).
//   4. It carries ALL input — keyboard, mouse, and gamepad — as JSON frames,
//      entirely separate from the WebRTC media path (the earlier assumption,
//      carried over from CloudNow/GFN, that input rides a WebRTC data channel
//      was wrong; a live RTCDataChannel capture saw zero input bytes).
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
// - `clientType` DETERMINES THE VIDEO TRANSPORT — CONFIRMED live 2026-07-23,
//   the decisive finding: `clientType=native` makes the server stream RAW UDP
//   (it sends `settings/udpforward` with ip/videoport/audioport and NEVER
//   `settings/webrtc`), while `clientType=web` makes it send `settings/webrtc`
//   and use WebRTC. Boosteroid's own bundle enumerates "native"/"tv"/"atv", so
//   a native TV client IS anticipated — but as a RAW-UDP client, not a WebRTC
//   one. Since this app streams via WebRTC (livekit), it must declare
//   `clientType=web` to get the transport it actually implements. (An earlier
//   pass used `native` on the theory that "we're a native TV app"; that was the
//   root cause of no video — the server set us up for a UDP stream we never
//   listen for.) Implementing the raw-UDP path instead would be a separate,
//   much larger effort (a UDP RTP receiver keyed by the `stream/key` value).
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
//     {type:"controller", action:"pad", id, hat} — CONFIRMED 2026-07-24 from
//     catch-events.js: `hat` is a DIRECTION BITMASK (up=1, right=2, down=4,
//     left=8) OR'd for diagonals (up+left=9, up+right=3, down+left=12,
//     down+right=6), and hat=0 is sent on release. NOT a POV-hat rotation
//     number. `id` is a NUMBER on the wire (not a string).
//   controller rumble (SERVER -> client): {type:"controller",
//     action:"rumble", id, left, right} — documented for completeness;
//     not wired to any vibration API on this client yet.
//
// NOT implemented: absolute/locked mouse cursor modes, and exact diagonal
// D-pad hat values — both precision/cosmetic gaps, see TODOs above and in
// InputSender, not correctness gaps.
actor BoosteroidControlChannel {
    enum IncomingEvent {
        /// CONFIRMED 2026-07-23: the server pushes `{"type":"settings",
        /// "action":"webrtc"}` on this socket to tell the client to start the
        /// WebRTC engine — the web client's `WebRtcTransport.connect()` (the
        /// getIceServers/call/ICE chain) is invoked ONLY from this message's
        /// handler. This is THE signal StreamController waits for before doing
        /// any WebRTC signaling. See this file's header for the full flow.
        case webrtcEngineReady
        /// The `{"type":"stream", ...}` config burst (bitrate/framerate/key)
        /// the server sends once the session is live. Used as a fallback
        /// trigger to start WebRTC when attaching to/taking over a session
        /// that was already initialized elsewhere (a device *switch*, where
        /// the server re-syncs this burst but does NOT re-send settings/webrtc
        /// — CONFIRMED via a live switch test).
        case sessionActive
        case controllerAck(name: String, id: String)
        case controllerRumble(id: String, left: Double, right: Double)
        case raw(type: String?, action: String?)
        case closed
        case failed(String)
    }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)
    private var idCmdCounter: Int = 0
    private var statusFramerate: Int = 60
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
	
        os: String = "win",
        devType: String = "desktop",
        clientType: String = "web"
    ) -> AsyncStream<IncomingEvent> {
        statusFramerate = refreshRate
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
                    await handle(text: text, continuation: continuation)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handle(text: text, continuation: continuation)
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
    private func handle(text: String, continuation: AsyncStream<IncomingEvent>.Continuation) async {
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
        // CONFIRMED 2026-07-23: `settings/webrtc` is the "start the WebRTC
        // engine now" signal; the `stream/*` burst (bitrate/framerate/key)
        // marks the session as live. See IncomingEvent's doc comments.
        if type == "settings", action == "webrtc" {
            continuation.yield(.webrtcEngineReady)
            return
        }
        // CONFIRMED 2026-07-23 (THE frames-0 fix): after the WebRTC peer
        // connects, the server sends `{"type":"stream","action":"getstatus"}`
        // and WAITS for the client's readiness reply before it starts sending
        // video. The web client answers with keyboard/language + a
        // stream/status:ok (carrying client params). Without this the peer
        // stays fully connected but 0 bytes ever arrive. Reply here.
        if type == "stream", action == "getstatus" {
            await sendStatusHandshake()
            continuation.yield(.sessionActive)
            return
        }
        if type == "stream" {
            continuation.yield(.sessionActive)
            return
        }
        continuation.yield(.raw(type: type, action: action))
    }

    /// Replies to the server's `stream/getstatus` with the readiness handshake
    /// the web client sends — this is what makes the server actually start
    /// pushing video (see the getstatus note in handle()).
    private func sendStatusHandshake() async {
        await send(type: "keyboard", action: "language", fields: ["code": 1033]) // 1033 = en-US LCID
        await send(type: "stream", action: "status", fields: [
            "value": "ok",
            "params": [
                "type": "web",
                "ver": "v_7.4.17",
                "gpu": "Apple, Apple TV",
                "proto": 1,
                "framerate_max": statusFramerate,
                "cursor_zip": false,
                "filler": false,
                "beta": 0,
                "rtcEngine": "webrtc",
                "rtcAudio": "pcm",
            ],
        ])
        await send(type: "stream", action: "refreshRate", fields: ["value": statusFramerate])
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(d) }
        return nil
    }
}
