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
    /// The per-node WebRTC gateway host, e.g. "https://sp7.cloud.boosteroid.com:443"
    /// — CONFIRMED to come from `session/details`'s `data.gw` field, see
    /// BoosteroidClient.fetchSessionDetails.
    private let nodeBaseUrl: String
    private let sessionId: String
    private let cookies: [String: String]
    /// Readable so session teardown can hang up THIS peer connection.
    /// `hangup` identifies the connection to tear down by `peerid`, so it has
    /// to be this exact value — passing a fresh random one names a peer the
    /// node has never heard of, which is what made it answer 500.
    let peerId: String = String(Double.random(in: 0..<1))

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": BoosteroidAuth.userAgent]
        return URLSession(configuration: config)
    }()

    private var iceCandidatePollTask: Task<Void, Never>?

    var onEvent: ((SignalingEvent) -> Void)?

    /// SUSPECTED FIX 2026-07-22 (not live-confirmed — didn't want to risk
    /// disrupting a real user's own active session to test it): every
    /// `webrtc/api/*` call to the per-node host below was previously sent
    /// with NO cookies and no auth of any kind — the browser's own calls to
    /// the exact same endpoints always carry cookies automatically (same
    /// parent domain, `cloud.boosteroid.com` / `sp7.cloud.boosteroid.com`),
    /// so that was never actually tested against Boosteroid's real
    /// behavior. A reported crash matching Swift/Foundation's exact
    /// "the data couldn't be read because it is missing" message — which is
    /// what `JSONDecoder` throws when handed a zero-byte response body —
    /// happening right as the game loads (i.e. right when these calls would
    /// fire) is consistent with the node rejecting an unauthenticated
    /// request with an empty body instead of the expected JSON. Cookies are
    /// threaded through here now; if this wasn't the actual cause, the next
    /// thing to check is whether `getIceServers`/`getParams` ever return a
    /// genuinely empty 200 body for some other reason.
    init(nodeBaseUrl: String, sessionId: String, cookies: [String: String]) {
        self.nodeBaseUrl = nodeBaseUrl
        self.sessionId = sessionId
        self.cookies = cookies
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

    /// CONFIRMED 2026-07-24 (real device report): this failed with Foundation's
    /// "The data couldn't be read because it is missing", which is
    /// `DecodingError.keyNotFound` — NOT an empty body (that decodes to
    /// "isn't in the correct format"). So the node answered with valid JSON that
    /// simply had no `iceServers` key, i.e. almost certainly `{}` because the
    /// session wasn't ready to negotiate yet.
    ///
    /// So a keyless/empty response is treated as "not ready, retry" rather than
    /// a hard failure, and the final error carries the actual body so the shape
    /// is never a guess again.
    func fetchIceServers() async throws -> [IceServer] {
        let data = try await getUntilReady(path: "getIceServers")
        guard let decoded = try? JSONDecoder().decode(IceServersResponse.self, from: data),
              !decoded.iceServers.isEmpty else {
            throw SignalingError.callFailed(
                "getIceServers returned no ICE servers (body: \(Self.preview(data)))."
            )
        }
        return decoded.iceServers
    }

    func fetchParams() async throws -> StreamParams {
        let data = try await getUntilReady(path: "getParams")
        guard let decoded = try? JSONDecoder().decode(StreamParams.self, from: data) else {
            throw SignalingError.callFailed(
                "getParams returned unusable params (body: \(Self.preview(data)))."
            )
        }
        return decoded
    }

    /// GETs a signaling endpoint, waiting out the window where the assigned
    /// machine exists but its streaming service isn't up yet.
    ///
    /// CONFIRMED 2026-07-24 from a real failure body: the node answers
    /// `502 {"error":"Bad Gateway","message":"Target service unavailable"}`
    /// while the VM behind the gateway is still booting. `session/details`
    /// hands out the gateway as soon as the session goes "LI", which is EARLIER
    /// than the VM being able to negotiate — so this is expected, not an error,
    /// and the only correct response is to keep asking.
    ///
    /// Retries on: a 5xx / "service unavailable" body, an empty body, and a
    /// body that simply doesn't parse yet. Gives up after `readyTimeout` with
    /// the real body attached.
    private func getUntilReady(path: String, readyTimeout: TimeInterval = 90) async throws -> Data {
        let deadline = Date().addingTimeInterval(readyTimeout)
        var lastStatus = 0
        var lastData = Data()
        while Date() < deadline {
            let (data, response) = try await session.data(for: authenticatedRequest(url(path)))
            lastStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastData = data
            let bootingUp = lastStatus >= 500
                || data.isEmpty
                || Self.preview(data).localizedCaseInsensitiveContains("unavailable")
            if !bootingUp { return data }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw SignalingError.callFailed(
            "\(path) never became available within \(Int(readyTimeout))s "
            + "(last HTTP \(lastStatus), body: \(Self.preview(lastData))). "
            + "The assigned machine's streaming service never came up."
        )
    }

    private static func preview(_ data: Data) -> String {
        String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
    }


    // MARK: Send Offer / Receive Answer
    //
    // TODO(protocol): body/response shape assumed from the upstream
    // webrtc-streamer OSS convention — NOT confirmed against real bytes. If
    // this fails against the real server, that's the first thing to
    // re-capture (e.g. via a local mitmproxy on your own Mac rather than the
    // sandboxed browser tool, which blocks raw body dumps).
    func sendOffer(sdp: String) async throws -> String {
        var request = authenticatedRequest(url("call"), method: "POST")
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
            var request = authenticatedRequest(url("addIceCandidate"), method: "POST")
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
                    let (data, _) = try await self.session.data(for: self.authenticatedRequest(self.url("getIceCandidate")))
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

    /// Adds the same Cookie/Origin/Referer/Accept headers `BoosteroidClient`
    /// uses for the main `cloud.boosteroid.com` API — see this file's init
    /// doc comment for why this node host needed the same treatment.
    private func authenticatedRequest(_ url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        req.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        req.setValue(BoosteroidAuth.apiBaseUrl, forHTTPHeaderField: "Origin")
        req.setValue(BoosteroidAuth.apiBaseUrl + "/dashboard", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

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
