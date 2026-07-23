import Foundation

// MARK: - Boosteroid Realtime (WebSocket) Client
//
// CONFIRMED 2026-07-22, but via STATIC analysis, not live traffic capture:
// two separate live-capture attempts (patching `window.WebSocket` from
// page-context JS, both immediately before and well after triggering a real
// queue) caught zero connections, despite the web UI's "Posição na fila"
// (queue position) visibly updating live with no corresponding REST poll.
// The reason turned out to be structural: this connection is opened once,
// app-wide, right after login/token-refresh — by the time any post-
// navigation script injection can run, Boosteroid's own bundle has already
// executed and grabbed its reference to the real `WebSocket` constructor.
//
// NOTE: this client exists purely to show a live numeric queue position —
// it is NOT needed to know when a session becomes active. That's
// BoosteroidClient's `last-session` endpoint, CONFIRMED reliable end-to-end
// (EN -> LI transition) once a genuinely fresh session is enqueued — see its
// Session Lifecycle note. An earlier pass through this investigation
// mistakenly concluded last-session was broken/stale, based on one account
// that had a leftover, never-cleared session confusing repeat lookups; that
// was account-state, not an endpoint problem.
//
// The real mechanism was instead found by fetching Boosteroid's own
// (unminified-enough) Angular bundle chunks and reading the relevant
// service's source directly — CONFIRMED from `chunk-D5WQZFGI.js`:
//
//   buildWebsocketUrl(e) {
//     let t = e.wss ? "wss:" : "ws:", o = new URL(t + e.address);
//     o.port = e.port;
//     o.searchParams.append("uid", e.uid.toString());
//     o.searchParams.append("token", e.token);
//     return o;
//   }
//   // called as: this.connect({ uid: t.id, token: o.access_token,
//   //   wss: !!ue.WSS_PORT, port: ue.WSS_PORT ?? ue.WS_PORT, address: ue.WS_HOST })
//
// with the real config values (from `chunk-BA6XJICU.js`):
//   WS_HOST: "cloud.boosteroid.com/ws", WS_PORT: "443", WSS_PORT: "443"
//
// i.e. the real URL is `wss://cloud.boosteroid.com/ws?uid=<id>&token=<jwt>`,
// where `uid` is the numeric id from GET /api/v1/user and `token` is the
// RAW access-token JWT (no "Bearer " prefix — that's an HTTP header
// convention, not part of the token itself).
//
// Every message is JSON: `{"type":..., "action":..., "value":...}`.
// CONFIRMED handling from the same bundle: `action === "closed"` (with a
// specific `value` enum member) means the token was rejected and needs
// refreshing; `type === "pong"` is a heartbeat reply to a client-sent ping.
// CONFIRMED (from the app's own NgRx state shape in `chunk-MH64ZJOD.js`)
// that queue-position pushes carry `value: {appId, eta, position}` — but
// the exact `type`/`action` string used to ROUTE that specific message was
// never captured (the lazy-loaded chunk containing that effect never
// loaded on any page visited during this investigation, only the reducer
// shape did). This client therefore pattern-matches generically: any
// message whose `value` is an object containing both `appId` and
// `position` is treated as a queue update, regardless of its `type`/
// `action`. Anything else is surfaced via `.raw` — not needed for the app
// to function (see NOTE above), but useful if a future pass wants to
// display richer queue state (ETA formatting, "your turn" push notices,
// etc.) than what last-session's plain EN/LI status offers.
actor BoosteroidRealtimeClient {
    enum Event {
        case queueUpdate(appId: Int, position: Int?, eta: Int?)
        /// Surfaced for anything not recognized as a queue update, so real
        /// device testing can capture the still-unconfirmed "ready" message
        /// shape (see header comment).
        case raw(type: String?, action: String?, description: String)
        case closed(code: URLSessionWebSocketTask.CloseCode, reason: String?)
        case failed(String)
    }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)

    /// Connects and returns a stream of decoded events. The stream finishes
    /// when the socket closes or errors — callers should treat that as "stop
    /// relying on this for progress" and fall back to their own timeout,
    /// same as if this connection had never existed.
    func connect(userId: String, token: String) -> AsyncStream<Event> {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "cloud.boosteroid.com"
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "uid", value: userId),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = components.url else {
            return AsyncStream { $0.finish() }
        }
        let wsTask = session.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()

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
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func receiveLoop(task: URLSessionWebSocketTask, continuation: AsyncStream<Event>.Continuation) async {
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
        continuation.finish()
    }

    private static func handle(text: String, continuation: AsyncStream<Event>.Continuation) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let type = obj["type"] as? String
        let action = obj["action"] as? String

        // Lenient on purpose: a real message carrying this shape has never
        // actually been observed (see header comment) — only inferred from
        // NgRx state — so this tolerates appId/position/eta arriving as
        // either JSON numbers or numeric strings rather than assuming.
        if let value = obj["value"] as? [String: Any], let appId = Self.asInt(value["appId"]) {
            continuation.yield(.queueUpdate(appId: appId, position: Self.asInt(value["position"]), eta: Self.asInt(value["eta"])))
            return
        }
        if type == "pong" { return }
        if action == "closed" {
            continuation.yield(.closed(code: .normalClosure, reason: action))
            return
        }
        let valueDescription = (obj["value"] as Any?).map { String(describing: $0) } ?? "nil"
        continuation.yield(.raw(type: type, action: action, description: valueDescription))
    }

    private static func asInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}
