import Foundation

// MARK: - Signaling Events

enum SignalingEvent {
    case connected
    case disconnected(reason: String)
    case offer(sdp: String)
    case remoteICE(candidate: String, sdpMid: String?, sdpMLineIndex: Int?)
    case log(String)
    case error(String)
}

// MARK: - Boosteroid WebRTC Signaling Client
//
// CONFIRMED 2026-07-22 by capturing real traffic (Chrome network inspector)
// while starting and ending an actual eFootball stream on cloud.boosteroid.com.
// This is a genuine implementation, not a guess — but a few gaps remain
// (marked TODO(protocol) below) because the safety layer on the browser
// automation tooling blocks dumping raw JS source / request bodies that look
// like cookie/query-string blobs, so the exact bodies of `call` and
// `addIceCandidate` weren't captured, only their existence, method, and query
// parameters.
//
// Architecture, confirmed end-to-end:
//   1. POST cloud.boosteroid.com/api/v2/streaming/session/enqueue
//        → 204, no body observed. Puts the account in a queue for a free VM.
//        The queue UI ("Posição na fila: N") updates live without visible
//        repeated polling requests — TODO(protocol): almost certainly pushed
//        over a WebSocket (there's no REST poll in the capture), but that
//        socket's URL/protocol wasn't isolated. Confirm before relying on
//        this for real queue-position UI.
//   2. Once a VM is assigned, the browser navigates to:
//        cloud.boosteroid.com/static/streaming/streaming.html?sessionId={uuid}
//      That page is a bundled JS client built on:
//        - `webrtcstreamear/webrtcstreamer.js` — a REST-based WebRTC signaling
//          helper matching the shape of the open-source project
//          "webrtc-streamer" (github.com/mpromonet/webrtc-streamer): getIceServers,
//          getParams, call, addIceCandidate, getIceCandidate. This IS the
//          actual media signaling transport — confirmed by the request log.
//        - `janus.js` / `janus-helper.js` — also loaded, purpose unconfirmed
//          (TODO(protocol): likely used for something other than the media
//          path, e.g. chat/cursor features — the media signaling clearly goes
//          through the REST API above, not a Janus WebSocket, based on the
//          captured request list).
//   3. POST cloud.boosteroid.com/api/v1/streaming/session/details?sessionId=...
//        → 200. Almost certainly returns the per-node signaling host (e.g.
//        the confirmed `sp0.cloud.boosteroid.com` seen below) plus session
//        metadata. TODO(protocol): exact response body not captured — infer
//        the host field name from this response once you can log it (e.g.
//        console.log inside a local proxy, or a MITM proxy on your own
//        machine — the in-tool JS dump was blocked as looking like exfil).
//   4. All WebRTC signaling happens against that per-node host, confirmed:
//        GET  {node}/webrtc/api/getIceServers?sessionId={id}
//          → {"iceServers":[{"credential":"...","urls":["turn:HOST:3478?transport=udp"],
//              "username":"<unixSeconds>:boosteroid"}],"iceTransportPolicy":"all"}
//          (response captured verbatim from a live session)
//        GET  {node}/webrtc/api/getParams?sessionId={id}
//          → {"codec":"H264","version":1}
//          (response captured verbatim — this session was H.264 only; whether
//          H.265/AV1 are ever offered is unconfirmed)
//        POST {node}/webrtc/api/call?peerid={rand}&sessionId={id}
//          → sends the local SDP offer, presumably returns the remote answer.
//          TODO(protocol): request/response body not captured — by convention
//          in the webrtc-streamer project this is `{"sdp":"...","type":"offer"}`
//          in and a similar `{"sdp":"...","type":"answer"}` out, but that's an
//          assumption carried over from the upstream OSS project, not observed
//          here directly.
//        POST {node}/webrtc/api/addIceCandidate?peerid={rand}&sessionId={id}
//          → called once per locally-trickled ICE candidate (8 times in the
//          captured session). TODO(protocol): body assumed to be
//          `{"candidate":"...","sdpMid":"...","sdpMLineIndex":N}` per the OSS
//          convention; not confirmed byte-for-byte.
//        GET  {node}/webrtc/api/getIceCandidate?peerid={rand}&sessionId={id}
//          → polls for remote ICE candidates (REST polling, not push — this
//          method needs to be called repeatedly, e.g. every second, until the
//          connection is established). TODO(protocol): exact response array
//          shape not captured.
//      `peerid` in the capture was a JS `Math.random()` value, e.g.
//      "0.9150882553499954" — a plain random float as a string, not a UUID.
//   5. Ending the session (clicking "End Session" → confirm) did NOT produce
//      a new call matching `/webrtc/api/` in a fetch-level capture — TODO(protocol):
//      teardown likely happens over XHR, `navigator.sendBeacon`, or whatever
//      channel is behind the still-unconfirmed queue/session WebSocket. Worth
//      checking for a `/webrtc/api/hangup` counterpart in the OSS project.
final class BoosteroidSignalingClient {
    /// The per-node WebRTC gateway host, e.g. "https://sp0.cloud.boosteroid.com".
    /// TODO(protocol): confirm where this comes from — presumably a field in
    /// the `session/details` response, not hardcoded.
    private let nodeBaseUrl: String
    private let sessionId: String
    private let peerId: String = String(Double.random(in: 0..<1))

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": BoosteroidAuth.userAgent]
        return URLSession(configuration: config)
    }()

    private var iceCandidatePollTask: Task<Void, Never>?

    var onEvent: ((SignalingEvent) -> Void)?

    init(nodeBaseUrl: String, sessionId: String) {
        self.nodeBaseUrl = nodeBaseUrl
        self.sessionId = sessionId
    }

    // MARK: Connect
    //
    // "Connecting" here just means confirming the node is reachable and
    // fetching ICE servers + codec params before the peer connection is built
    // — there's no persistent socket to open, unlike a WebSocket signaling
    // design.

    func connect() async throws {
        _ = try await fetchIceServers()
        onEvent?(.connected)
    }

    func fetchIceServers() async throws -> [IceServer] {
        let (data, _) = try await session.data(from: url("getIceServers"))
        let decoded = try JSONDecoder().decode(IceServersResponse.self, from: data)
        return decoded.iceServers
    }

    func fetchParams() async throws -> StreamParams {
        let (data, _) = try await session.data(from: url("getParams"))
        return try JSONDecoder().decode(StreamParams.self, from: data)
    }

    // MARK: Send Offer / Receive Answer
    //
    // TODO(protocol): body/response shape assumed from the upstream
    // webrtc-streamer OSS convention — NOT confirmed against real bytes. If
    // this fails against the real server, that's the first thing to
    // re-capture (e.g. via a local mitmproxy on your own Mac rather than the
    // sandboxed browser tool, which blocks raw body dumps).
    func sendOffer(sdp: String) async throws -> String {
        var request = URLRequest(url: url("call"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sdp": sdp, "type": "offer"])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SignalingError.callFailed(String(data: data, encoding: .utf8) ?? "")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let answerSdp = obj?["sdp"] as? String else {
            throw SignalingError.callFailed("No sdp in response: \(String(data: data, encoding: .utf8) ?? "")")
        }
        return answerSdp
    }

    // MARK: Send ICE Candidate

    func sendICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        Task {
            var request = URLRequest(url: url("addIceCandidate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var payload: [String: Any] = ["candidate": candidate]
            if let sdpMid { payload["sdpMid"] = sdpMid }
            if let sdpMLineIndex { payload["sdpMLineIndex"] = sdpMLineIndex }
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await session.data(for: request)
        }
    }

    // MARK: Poll for Remote ICE Candidates
    //
    // TODO(protocol): polling interval (1s here) is a guess. The captured
    // session only showed one `getIceCandidate` call, so the real interval —
    // or whether it stops after the connection is established — is unconfirmed.

    func startPollingRemoteICE() {
        iceCandidatePollTask?.cancel()
        iceCandidatePollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let (data, _) = try await self.session.data(from: self.url("getIceCandidate"))
                    if let candidates = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        for c in candidates {
                            guard let candidate = c["candidate"] as? String else { continue }
                            self.onEvent?(.remoteICE(
                                candidate: candidate,
                                sdpMid: c["sdpMid"] as? String,
                                sdpMLineIndex: c["sdpMLineIndex"] as? Int
                            ))
                        }
                    }
                } catch {
                    self.onEvent?(.log("getIceCandidate poll error: \(error.localizedDescription)"))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Disconnect

    func disconnect() {
        iceCandidatePollTask?.cancel()
        iceCandidatePollTask = nil
    }

    // MARK: Private

    private func url(_ path: String) -> URL {
        var comps = URLComponents(string: "\(nodeBaseUrl)/webrtc/api/\(path)")!
        var items = [URLQueryItem(name: "sessionId", value: sessionId)]
        if path != "getIceServers" && path != "getParams" {
            items.append(URLQueryItem(name: "peerid", value: peerId))
        }
        comps.queryItems = items
        return comps.url!
    }
}

// MARK: - Response Models (confirmed shapes)

struct IceServersResponse: Decodable {
    let iceServers: [IceServer]
    let iceTransportPolicy: String?
}

struct StreamParams: Decodable {
    let codec: String
    let version: Int
}

// MARK: - Errors

enum SignalingError: Error, LocalizedError {
    case invalidUrl(String)
    case callFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidUrl(let url): return "Invalid signaling URL: \(url)"
        case .callFailed(let msg): return "call failed: \(msg)"
        }
    }
}
