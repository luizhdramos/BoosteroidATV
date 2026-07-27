import AVFoundation
import Foundation
import LiveKitWebRTC
import Observation

// MARK: - Stream State

enum StreamState: Equatable {
    case idle
    case connecting
    case streaming
    case disconnected(reason: String)
    case failed(message: String)
}

// MARK: - Stream Statistics

struct StreamStats {
    var bitrateKbps: Int = 0
    var resolutionWidth: Int = 0
    var resolutionHeight: Int = 0
    var fps: Double = 0
    var rttMs: Double = 0
    var packetLossPercent: Double = 0
    var codec: String = ""
}

// MARK: - StreamController
//
// CONFIRMED 2026-07-22 against a real eFootball session: unlike GFN (where the
// SERVER sends the SDP offer and the client answers), Boosteroid's
// webrtc-streamer-style REST signaling has the CLIENT create the offer and
// POST it to `/webrtc/api/call`, receiving the server's answer in response.
// ICE is trickled both ways: locally-generated candidates are POSTed to
// `/webrtc/api/addIceCandidate`, remote candidates are polled via repeated
// GETs to `/webrtc/api/getIceCandidate` (see SignalingClient.swift for the
// exact confirmed/unconfirmed details of each call).
@Observable
@MainActor
final class StreamController: NSObject {
    private(set) var state: StreamState = .idle
    private(set) var stats = StreamStats()
    private(set) var videoTrack: LKRTCVideoTrack?
    /// Human-readable connect progress, shown under "Connecting…" so a stuck
    /// session says WHERE it's stuck instead of hanging silently.
    private(set) var stage: String = ""
    /// Rolling log of raw control-channel messages, surfaced on failure to help
    /// diagnose a stuck connect on a real device (no console access there).
    private(set) var controlLog: [String] = []
    /// Live diagnostics shown on-screen while streaming — so a BLACK SCREEN
    /// says whether ICE connected, a video track arrived, and frames are
    /// decoding (no device console available).
    private(set) var iceState: String = "new"
    /// The DTLS/overall peer connection state — distinguishes "ICE connected
    /// but DTLS never completed" (data channel never opens, server sends no
    /// media) from "fully connected".
    private(set) var peerConnState: String = "new"
    private(set) var dataChannelState: String = "-"
    private(set) var gotVideoTrack = false
    private(set) var framesDecoded = 0
    // Extra decode diagnostics to tell "packets arriving but not assembled"
    // from "frames assembled but not decoding" (codec/keyframe issue).
    private(set) var framesReceived = 0
    private(set) var keyFramesDecoded = 0
    private(set) var packetsReceived = 0
    private(set) var codecName = "?"
    // Per-second rates for the overlay: Stream FPS = frames arriving from the
    // server, Decode FPS = frames the local hardware decodes, RTT = network
    // round-trip. Computed as deltas across the ~1s stats tick.
    private(set) var streamFps = 0
    private(set) var decodeFps = 0
    private(set) var rttMs = 0
    private var lastBytesReceived = 0
    private var lastFramesReceivedSample = 0
    private var lastFramesDecodedSample = 0
    // Controller input diagnostics (mirrored from InputSender each stats tick)
    // so the HUD can show whether a pad is seen, whether frames are being
    // sent, and whether the server acked the controller handshake.
    private(set) var controllerCount = 0
    private(set) var controllerEventsSent = 0
    private(set) var controllerAckId: String = "-"
    /// Cursor position reported by the server, in remote-desktop pixels.
    /// nil until (or unless) the server sends one — see the `.cursor` note in
    /// BoosteroidControlChannel.
    private(set) var serverCursor: CGPoint?
    /// Field names of the last cursor message, so an unrecognised shape can be
    /// identified from a real session instead of guessed at.
    private(set) var cursorFields: [String] = []

    private var peerConnection: LKRTCPeerConnection?
    /// CONFIRMED 2026-07-23: Boosteroid's webrtcstreamer.js always creates a
    /// "ClientDataChannel" and includes it (m=application) in the SDP offer.
    /// The app omitted it, and the server appears to gate video on it (peer
    /// connects and a track arrives, but 0 frames decode). Retained so it
    /// isn't deallocated.
    private var clientDataChannel: LKRTCDataChannel?
    private var signaling: BoosteroidSignalingClient?
    private(set) var inputSender: InputSender?
    private let controlChannel = BoosteroidControlChannel()
    private var controlChannelTask: Task<Void, Never>?
    private var watchdogTasks: [Task<Void, Never>] = []
    private var didStartWebRTC = false
    // CONFIRMED 2026-07-23 from webrtcstreamer.js: local ICE candidates are
    // BUFFERED ("earlyCandidates") and only POSTed to the server AFTER the
    // answer is received. The app was sending them immediately (before the
    // `call`), so the server never registered our address and sent no media
    // (ICE "connected" via peer-reflexive, but 0 bytes). Buffer + flush.
    private var iceCanSend = false
    private var pendingLocalICE: [(sdp: String, sdpMid: String?, sdpMLineIndex: Int)] = []
    private(set) var videoView: VideoSurfaceView?
    private var statsTask: Task<Void, Never>?
    private var sessionInfo: SessionInfo?
    private var settings = StreamSettings()

    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        let encoderFactory = LKRTCDefaultVideoEncoderFactory()
        let decoderFactory = LKRTCDefaultVideoDecoderFactory()
        return LKRTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()

    // MARK: Connect

    // CONFIRMED 2026-07-23 (see BoosteroidControlChannel's header for the full
    // evidence): the control WebSocket is the PRIMARY connection. Opening it
    // claims the session for this device, and the server only starts feeding
    // WebRTC media after the client has claimed via that socket AND received a
    // `settings/webrtc` signal on it. So this now opens the control socket
    // FIRST and defers all WebRTC signaling until that signal arrives — the
    // exact order the web client uses. The previous WebRTC-first ordering is
    // why the app only ever showed video when a browser had already claimed
    // the session, and why opening the control socket after WebRTC (a first
    // buggy pass) black-screened everything.
    func connect(session: SessionInfo, settings: StreamSettings, cookies: [String: String]) async {
        switch state {
        case .connecting, .streaming: return
        default: break
        }
        state = .connecting
        stage = "Opening control channel…"
        controlLog = []
        didStartWebRTC = false
        sessionInfo = session
        self.settings = settings

        // Both come from session/details' CONFIRMED success body
        // ({"data":{"gw":...,"queryString":...}}) — see
        // BoosteroidClient.fetchSessionDetails. Guarded defensively since
        // SessionInfo instances built from last-session (still-queued state)
        // populate neither.
        guard let nodeBaseUrl = session.nodeBaseUrl else {
            state = .failed(message: "Session became active but its node/gateway host (nodeBaseUrl) is missing — this shouldn't happen once fetchSessionDetails has run; please report this.")
            return
        }
        guard let queryString = session.queryString else {
            state = .failed(message: "Session is missing its streaming token (queryString) — the control channel can't claim the session without it. This shouldn't happen once fetchSessionDetails has run; please report this.")
            return
        }

        let client = BoosteroidSignalingClient(nodeBaseUrl: nodeBaseUrl, sessionId: session.sessionId, cookies: cookies)
        client.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleSignalingEvent(event) }
        }
        signaling = client

        // 1. Open the control WebSocket FIRST — this claims the session for
        //    this device and is what the server gates media on.
        let (width, height) = Self.parseResolution(settings.resolution)
        let sender = InputSender(controlChannel: controlChannel, surfaceWidth: width, surfaceHeight: height)
        inputSender = sender
        videoView?.inputHandler = sender

        controlChannelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.controlChannel.connect(
                nodeBaseUrl: nodeBaseUrl,
                queryString: queryString,
                resolutionWidth: width,
                resolutionHeight: height,
                refreshRate: self.settings.fps,
                maxBitrateBps: Self.targetBitrateBps(settings: self.settings, width: width, height: height)
            )
            sender.start()
            self.stage = "Control channel open — waiting for the server to start video…"

            // Fallback: the confirmed trigger is `settings/webrtc` (fresh) or a
            // `stream/*` burst (take-over). If neither arrives in a few seconds
            // — e.g. the server sends the go-ahead in a shape we don't
            // recognize — start WebRTC anyway; the session is already claimed,
            // and the REST calls will surface a clear error if it's genuinely
            // too early rather than hanging forever.
            self.watchdogTasks.append(Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, !self.didStartWebRTC, self.state == .connecting else { return }
                self.controlLog.append("(no webrtc/stream signal in 6s — starting anyway)")
                await self.startWebRTCMedia(client: client)
            })
            // Overall watchdog so a stuck connect fails with context instead of
            // spinning indefinitely.
            self.watchdogTasks.append(Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard let self, self.state == .connecting else { return }
                self.state = .failed(message:
                    "Timed out after 45s. Last step: \(self.stage)\n\nControl messages received:\n" +
                    (self.controlLog.isEmpty ? "(none)" : self.controlLog.joined(separator: "\n")))
            })

            for await event in stream {
                // Input events (controller acks etc.) go to the sender.
                sender.handleIncoming(event)
                switch event {
                case .webrtcEngineReady:
                    self.controlLog.append("settings/webrtc (start engine)")
                    if !self.didStartWebRTC { await self.startWebRTCMedia(client: client) }
                case .sessionActive:
                    self.controlLog.append("stream/* burst (session active)")
                    if !self.didStartWebRTC { await self.startWebRTCMedia(client: client) }
                case .raw(let type, let action):
                    self.controlLog.append("\(type ?? "?")/\(action ?? "?")")
                case .cursor(let x, let y, _, let fields):
                    self.cursorFields = fields
                    if let x, let y { self.serverCursor = CGPoint(x: x, y: y) }
                case .controllerAck(let name, _):
                    self.controlLog.append("controller connected: \(name)")
                case .failed(let message):
                    self.controlLog.append("socket failed: \(message)")
                    if !self.didStartWebRTC {
                        self.state = .failed(message: "Control channel failed before streaming could start: \(message)")
                    }
                case .closed, .controllerRumble:
                    break
                }
            }
        }
    }

    /// The WebRTC signaling chain (getIceServers → getParams → offer → call →
    /// ICE), CONFIRMED against real traffic. Called only after the control
    /// channel signals the engine should start (see connect()).
    private func startWebRTCMedia(client: BoosteroidSignalingClient) async {
        // Guard against a duplicate trigger racing in (the signal and the
        // fallback timer can both fire).
        guard !didStartWebRTC else { return }
        didStartWebRTC = true
        do {
            stage = "Starting video — fetching ICE servers…"
            let iceServers = try await client.fetchIceServers()
            // CONFIRMED this session negotiated H.264 — getParams told us so
            // before we ever built the peer connection. TODO(protocol): decide
            // whether to trust this over the user's StreamSettings.codec
            // choice, or whether other codecs can be requested some other way.
            let params = try await client.fetchParams()
            print("[StreamController] Boosteroid params: codec=\(params.codec) version=\(params.version)")

            stage = "Sending WebRTC offer…"
            try await createPeerConnectionAndOffer(iceServers: iceServers)
            stage = "Offer accepted — waiting for video…"
            client.startPollingRemoteICE()
        } catch {
            state = .failed(message: "Video setup failed while: \(stage)\n\(error.localizedDescription)")
        }
    }

    private static func parseResolution(_ resolution: String) -> (Int, Int) {
        let parts = resolution.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return (1920, 1080) }
        return (w, h)
    }

    /// Max bitrate (bits/sec) to request via the control channel's
    /// `stream/bandwidth` message. Manual: the user's 3–80 Mbps choice.
    /// Automatic: Boosteroid's own resolution→bitrate ladder (CONFIRMED
    /// 2026-07-24 from streaming.js: <0.9MP 7 / <1.0MP 10 / <1.2MP 14 /
    /// <1.5MP 17 / <1.9MP 20 / ≥1.9MP 24 Mbps).
    static func targetBitrateBps(settings: StreamSettings, width: Int, height: Int) -> Int {
        if !settings.automaticBitrate {
            return min(80, max(3, settings.manualBitrateMbps)) * 1_000_000
        }
        switch width * height {
        case ..<900_000:   return 7_000_000
        case ..<1_000_000: return 10_000_000
        case ..<1_200_000: return 14_000_000
        case ..<1_500_000: return 17_000_000
        case ..<1_900_000: return 20_000_000
        default:           return 24_000_000
        }
    }

    func disconnect() {
        statsTask?.cancel()
        statsTask = nil
        inputSender?.stop()
        inputSender = nil
        controlChannelTask?.cancel()
        controlChannelTask = nil
        watchdogTasks.forEach { $0.cancel() }
        watchdogTasks = []
        Task { [controlChannel] in await controlChannel.disconnect() }
        clientDataChannel?.close()
        clientDataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        signaling?.disconnect()
        signaling = nil
        videoTrack = nil
        state = .idle
    }

    // MARK: Video View Binding

    func bindVideoView(_ view: VideoSurfaceView) {
        videoView = view
        view.inputHandler = inputSender
    }

    // MARK: Private — Signaling Events (remote ICE only — offer/answer is a
    // direct request/response, not an event, in this REST design)

    private func handleSignalingEvent(_ event: SignalingEvent) {
        switch event {
        case .connected, .offer:
            break // offer/answer handled directly in connect(), not as an event
        case .remoteICE(let candidate, let sdpMid, let sdpMLineIndex):
            let ice = LKRTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(sdpMLineIndex ?? 0), sdpMid: sdpMid)
            peerConnection?.add(ice) { _ in }
        case .disconnected(let reason):
            state = .disconnected(reason: reason)
        case .log(let message):
            print("[StreamController] \(message)")
        case .error(let message):
            state = .failed(message: message)
        }
    }

    // MARK: Private — Peer Connection (client-is-offerer flow)

    private func createPeerConnectionAndOffer(iceServers: [IceServer]) async throws {
        let config = LKRTCConfiguration()
        config.iceServers = iceServers.map {
            LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        config.sdpSemantics = .unifiedPlan

        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw StreamControllerError.peerConnectionCreationFailed
        }
        peerConnection = pc
        iceCanSend = false
        pendingLocalICE = []

        // Create the "ClientDataChannel" BEFORE the offer so it appears as an
        // m=application line — matching Boosteroid's own webrtcstreamer.js
        // (which the server appears to require before it starts sending video).
        let dcConfig = LKRTCDataChannelConfiguration()
        clientDataChannel = pc.dataChannel(forLabel: "ClientDataChannel", configuration: dcConfig)

        let offerConstraints = LKRTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        let offer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            pc.offer(for: offerConstraints) { sdp, error in
                if let error { cont.resume(throwing: error); return }
                if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: StreamControllerError.noSDP) }
            }
        }

        // Filter the offer to a SINGLE codec.
        // CONFIRMED 2026-07-23: with a raw multi-codec offer (H264+VP8+VP9+AV1)
        // the server streams packets (kbps > 0) but the client assembles 0
        // frames and can't identify the codec — a payload-type mismatch.
        // Restricting to one codec removes the ambiguity and lines the PTs up
        // like the browser's negotiation.
        //
        // Hardcoded H.264: confirmed the only codec Boosteroid delivers over
        // its WebRTC path. H.265/HEVC and AV1 only ship over its native app's
        // UDP transport (tested 2026-07 — HEVC over WebRTC silently fell back
        // to H.264, never negotiated). Also guards against a stale saved codec.
        let mungedSdp = SDPMunger.preferCodec(offer.sdp, codec: .h264)
        let finalOffer = LKRTCSessionDescription(type: .offer, sdp: mungedSdp)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(finalOffer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        guard let signaling else { throw StreamControllerError.noSDP }
        let answerSdp = try await signaling.sendOffer(sdp: finalOffer.sdp)
        let remoteDesc = LKRTCSessionDescription(type: .answer, sdp: answerSdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(remoteDesc) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        // Answer is set — now it's safe to send our ICE candidates (matches the
        // browser's earlyCandidates flush). Send everything gathered so far,
        // then let didGenerate send the rest live.
        iceCanSend = true
        for c in pendingLocalICE {
            signaling.sendICECandidate(candidate: c.sdp, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex)
        }
        pendingLocalICE = []
    }

    // MARK: Private — Stats

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let pc = self.peerConnection else { return }
                self.peerConnState = Self.peerStateLabel(pc.connectionState)
                self.dataChannelState = Self.dcStateLabel(self.clientDataChannel?.readyState)

                // Async getStats — no completion closure, so no nested Task and
                // nothing captured off the main actor. Parse the standard
                // inbound-rtp video stats inline.
                let report = await pc.statistics()
                var frames = 0, bytes = 0, w = 0, h = 0
                var framesRx = 0, keyFrames = 0, packets = 0
                var fps = 0.0
                var codecId = ""
                var codecs: [String: String] = [:]
                var rttSeconds: Double = -1
                for (_, stat) in report.statistics {
                    let v = stat.values
                    if stat.type == "codec", let mime = v["mimeType"] as? String {
                        codecs[stat.id] = mime
                    }
                    // Network RTT from the active ICE candidate pair.
                    if stat.type == "candidate-pair",
                       (v["nominated"] as? NSNumber)?.boolValue == true || (v["state"] as? String) == "succeeded",
                       let rtt = (v["currentRoundTripTime"] as? NSNumber)?.doubleValue {
                        rttSeconds = rtt
                    }
                    guard stat.type == "inbound-rtp" else { continue }
                    let kind = (v["kind"] as? String) ?? (v["mediaType"] as? String) ?? ""
                    guard kind == "video" else { continue }
                    frames = (v["framesDecoded"] as? NSNumber)?.intValue ?? frames
                    framesRx = (v["framesReceived"] as? NSNumber)?.intValue ?? framesRx
                    keyFrames = (v["keyFramesDecoded"] as? NSNumber)?.intValue ?? keyFrames
                    packets = (v["packetsReceived"] as? NSNumber)?.intValue ?? packets
                    fps = (v["framesPerSecond"] as? NSNumber)?.doubleValue ?? fps
                    w = (v["frameWidth"] as? NSNumber)?.intValue ?? w
                    h = (v["frameHeight"] as? NSNumber)?.intValue ?? h
                    bytes = (v["bytesReceived"] as? NSNumber)?.intValue ?? bytes
                    codecId = (v["codecId"] as? String) ?? codecId
                }
                let delta = max(0, bytes - self.lastBytesReceived)
                self.lastBytesReceived = bytes
                self.stats.bitrateKbps = delta * 8 / 1000
                self.stats.fps = fps
                self.stats.resolutionWidth = w
                self.stats.resolutionHeight = h
                // Keep the absolute-pointer math in step with the ACTUAL
                // decoded resolution — it can differ from what was merely
                // requested in Settings, and InputSender was otherwise frozen
                // on the requested value for the whole session (see
                // updateSurfaceSize's doc comment).
                self.inputSender?.updateSurfaceSize(width: w, height: h)
                self.framesDecoded = frames
                self.framesReceived = framesRx
                self.keyFramesDecoded = keyFrames
                self.packetsReceived = packets
                self.codecName = codecs[codecId] ?? (codecId.isEmpty ? "?" : codecId)

                // Per-second rates (tick is ~1s): frames received from the
                // server vs. frames decoded locally.
                self.streamFps = max(0, framesRx - self.lastFramesReceivedSample)
                self.decodeFps = max(0, frames - self.lastFramesDecodedSample)
                self.lastFramesReceivedSample = framesRx
                self.lastFramesDecodedSample = frames
                if rttSeconds >= 0 { self.rttMs = Int((rttSeconds * 1000).rounded()) }

                if let sender = self.inputSender {
                    self.controllerCount = sender.connectedControllerCount
                    self.controllerEventsSent = sender.controllerEventsSent
                    self.controllerAckId = sender.lastServerAckId ?? "none(provisional)"
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    nonisolated private static func peerStateLabel(_ s: LKRTCPeerConnectionState) -> String {
        switch s {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "unknown"
        }
    }

    nonisolated private static func dcStateLabel(_ s: LKRTCDataChannelState?) -> String {
        switch s {
        case .connecting: return "connecting"
        case .open: return "open"
        case .closing: return "closing"
        case .closed: return "closed"
        case nil: return "-"
        @unknown default: return "?"
        }
    }
}

// MARK: - Errors

enum StreamControllerError: Error {
    case noSDP
    case peerConnectionCreationFailed
}

// MARK: - LKRTCPeerConnectionDelegate

extension StreamController: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        guard let track = stream.videoTracks.first else { return }
        Task { @MainActor in
            self.videoTrack = track
            self.videoView?.videoTrack = track
            self.gotVideoTrack = true
            self.watchdogTasks.forEach { $0.cancel() }
            self.watchdogTasks = []
            self.stage = ""
            self.state = .streaming
            self.startStatsLoop()
        }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        let c = (sdp: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex))
        Task { @MainActor in
            // Buffer until the answer is set (see iceCanSend) — sending before
            // the server has processed our offer/call loses the candidates.
            if self.iceCanSend {
                self.signaling?.sendICECandidate(candidate: c.sdp, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex)
            } else {
                self.pendingLocalICE.append(c)
            }
        }
    }

   // nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
     //   let label = Self.iceStateLabel(newState)
       // Task { @MainActor in
        //    self.iceState = label
            // Don't tear the session down just because ICE reports "failed" or
            // "closed" — with a video track already flowing these can be
            // transient; surface it in diagnostics instead of killing a stream
            // that may still be (or resume) working.
        //}
   // }
    
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        Task { @MainActor in
            // Called safely on the MainActor
            let label = Self.iceStateLabel(newState)
            self.iceState = label
            
            // Don't tear the session down just because ICE reports "failed" or
            // "closed" — with a video track already flowing these can be
            // transient; surface it in diagnostics instead of killing a stream
            // that may still be (or resume) working.
        }
    }

    nonisolated private static func iceStateLabel(_ s: LKRTCIceConnectionState) -> String {
        switch s {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown"
        }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        // CONFIRMED 2026-07-23: this is NOT the input path. Boosteroid's own
        // webrtcstreamer.js opens a "ClientDataChannel" here (confirmed from
        // its source), but a live capture found zero input traffic on it —
        // ALL keyboard/mouse/controller input actually rides a separate JSON
        // WebSocket (BoosteroidControlChannel), unrelated to any data
        // channel. Left as a no-op; nothing observed to be needed here.
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
}
