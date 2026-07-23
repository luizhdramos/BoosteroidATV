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

    private var peerConnection: LKRTCPeerConnection?
    private var signaling: BoosteroidSignalingClient?
    private var inputSender: InputSender?
    private let controlChannel = BoosteroidControlChannel()
    private var controlChannelTask: Task<Void, Never>?
    private(set) var videoView: VideoSurfaceView?
    private var statsTimer: Timer?
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
                refreshRate: self.settings.fps
            )
            sender.start()
            var startedWebRTC = false
            for await event in stream {
                // Input events (controller acks etc.) go to the sender.
                sender.handleIncoming(event)
                // 2. Start WebRTC media only once the control plane says so:
                //    `settings/webrtc` on a fresh session, or the `stream/*`
                //    burst when taking over/switching to an existing one.
                switch event {
                case .webrtcEngineReady, .sessionActive:
                    if !startedWebRTC {
                        startedWebRTC = true
                        await self.startWebRTCMedia(client: client)
                    }
                case .failed(let message):
                    if !startedWebRTC { self.state = .failed(message: "Control channel failed before streaming could start: \(message)") }
                default:
                    break
                }
            }
        }
    }

    /// The WebRTC signaling chain (getIceServers → getParams → offer → call →
    /// ICE), CONFIRMED against real traffic. Called only after the control
    /// channel signals the engine should start (see connect()).
    private func startWebRTCMedia(client: BoosteroidSignalingClient) async {
        // Guard against a duplicate trigger racing in (webrtcEngineReady AND
        // the stream burst can both arrive).
        guard peerConnection == nil else { return }
        do {
            let iceServers = try await client.fetchIceServers()
            // CONFIRMED this session negotiated H.264 — getParams told us so
            // before we ever built the peer connection. TODO(protocol): decide
            // whether to trust this over the user's StreamSettings.codec
            // choice, or whether other codecs can be requested some other way.
            let params = try await client.fetchParams()
            print("[StreamController] Boosteroid params: codec=\(params.codec) version=\(params.version)")

            try await createPeerConnectionAndOffer(iceServers: iceServers)
            client.startPollingRemoteICE()
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    private static func parseResolution(_ resolution: String) -> (Int, Int) {
        let parts = resolution.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return (1920, 1080) }
        return (w, h)
    }

    func disconnect() {
        statsTimer?.invalidate()
        statsTimer = nil
        inputSender?.stop()
        inputSender = nil
        controlChannelTask?.cancel()
        controlChannelTask = nil
        Task { [controlChannel] in await controlChannel.disconnect() }
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
            peerConnection?.add(ice)
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

        var offerSdp = SDPMunger.preferCodec(offer.sdp, codec: settings.codec)
        offerSdp = SDPMunger.injectBandwidth(offerSdp, videoKbps: settings.maxBitrateKbps)
        let mungedOffer = LKRTCSessionDescription(type: .offer, sdp: offerSdp)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(mungedOffer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        guard let signaling else { throw StreamControllerError.noSDP }
        let answerSdp = try await signaling.sendOffer(sdp: mungedOffer.sdp)
        let remoteDesc = LKRTCSessionDescription(type: .answer, sdp: answerSdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(remoteDesc) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    // MARK: Private — Stats

    private func startStatsLoop() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.peerConnection?.statistics { report in
                    // TODO(protocol): parse `report` into StreamStats. The keys
                    // needed here (video decoder stats, RTT, packet loss) are
                    // standard WebRTC getStats() fields, so this part doesn't
                    // depend on Boosteroid specifics — just needs implementing.
                }
            }
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
            self.state = .streaming
            self.startStatsLoop()
        }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        Task { @MainActor in
            self.signaling?.sendICECandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex))
        }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        if newState == .failed || newState == .closed {
            Task { @MainActor in self.state = .disconnected(reason: "ICE connection \(newState)") }
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
