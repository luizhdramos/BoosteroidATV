import Foundation

// MARK: - Boosteroid REST Client
//
// CONFIRMED 2026-07-22 against real traffic from cloud.boosteroid.com (logged
// in, launched eFootball, played briefly, ended session). URLs and HTTP
// methods below are real; most request/response BODIES were not captured
// (the browser automation's exfil-prevention filter blocks dumping raw JS
// source or anything shaped like a cookie/query-string blob, which is how
// most of this was actually observed — via the network request log, not by
// reading client JS). Where a body shape is written below, it is inferred and
// marked TODO(protocol) — treat it as a starting guess, not a fact.
actor BoosteroidClient {
    // Ephemeral, cookies sent manually per-request: see BoosteroidAuthAPI for
    // why (URLSession's shared-cookie-jar auto-merge behavior was the actual
    // cause of an earlier 414 bug — every request builds its own Cookie
    // header from the caller-supplied dict instead).
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": BoosteroidAuth.userAgent]
        return URLSession(configuration: config)
    }()

    private let apiBase = "https://cloud.boosteroid.com/api"

    private func authenticatedRequest(_ url: URL, cookies: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = false
        req.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        req.setValue(BoosteroidAuth.apiBaseUrl, forHTTPHeaderField: "Origin")
        req.setValue(BoosteroidAuth.apiBaseUrl + "/dashboard", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: Catalog
    //
    // CONFIRMED 2026-07-22 live from a logged-in browser session:
    //   GET /api/v1/boostore/applications/installed?page=1&paginate=50
    //   — the "my library" list (see SessionState.swift for the confirmed
    //   response shape). Cookies alone are sufficient (same as /api/v1/user).
    //   GET /api/v1/boostore/carousel?isSub=true   — hero banner carousel
    //   GET /api/v1/boostore/applications/{id}     — single game detail

    func fetchLibrary(cookies: [String: String]) async throws -> [GameInfo] {
        let url = URL(string: "\(apiBase)/v1/boostore/applications/installed?page=1&paginate=50")!
        let (data, response) = try await session.data(for: authenticatedRequest(url, cookies: cookies))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("fetchLibrary", String(data: data, encoding: .utf8) ?? "")
        }
        let page = try JSONDecoder().decode(BoosteroidPaginatedApplications.self, from: data)
        return page.data.map(GameInfo.init)
    }

    func fetchApplication(id: String) async throws -> GameInfo {
        // CONFIRMED URL. TODO(protocol): response body shape not captured —
        // decode once you have a real sample.
        let (data, response) = try await session.data(from: URL(string: "\(apiBase)/v1/boostore/applications/\(id)")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("fetchApplication", String(data: data, encoding: .utf8) ?? "")
        }
        throw BoosteroidClientError.notImplemented("fetchApplication — decode step not written; response shape unconfirmed")
    }

    // MARK: Current User
    //
    // CONFIRMED: GET /api/v1/user returns 200 for an authenticated (cookie)
    // session — good liveness/validation check for AuthManager, but response
    // body shape unconfirmed.

    func fetchCurrentUser() async throws {
        let (data, response) = try await session.data(from: URL(string: "\(apiBase)/v1/user")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("fetchCurrentUser", String(data: data, encoding: .utf8) ?? "")
        }
        // TODO(protocol): decode into AuthUser once the body shape is known.
    }

    // MARK: Session Lifecycle
    //
    // CONFIRMED flow, real endpoints, in order:
    //   1. POST /api/v2/streaming/session/enqueue → 204 (starts the queue)
    //   2. Queue position is shown live in the UI without visible REST
    //      polling — TODO(protocol): almost certainly a WebSocket; URL/protocol
    //      not isolated in this pass.
    //   3. Once ready, the UI navigates to
    //      cloud.boosteroid.com/static/streaming/streaming.html?sessionId={uuid}
    //   4. That page calls POST /api/v1/streaming/session/details?sessionId=...
    //      → 200, presumably returning the per-node WebRTC gateway host (e.g.
    //      the confirmed "sp0.cloud.boosteroid.com") — see SessionInfo.

    func createSession(_ request: SessionCreateRequest, token: String) async throws -> SessionInfo {
        var req = URLRequest(url: URL(string: "\(apiBase)/v2/streaming/session/enqueue")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // TODO(protocol): request body unconfirmed — guessing at minimum the
        // application id is required. Replace once captured.
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["applicationId": request.gameId])
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
            throw BoosteroidClientError.requestFailed("createSession/enqueue", String(data: data, encoding: .utf8) ?? "")
        }
        throw BoosteroidClientError.notImplemented(
            "createSession — enqueue call succeeds (204) but the queue-ready signal (WebSocket?) and the session/details response shape (which should yield SessionInfo.nodeBaseUrl) are not yet captured/decoded."
        )
    }

    /// TODO(protocol): queue progress appears to be pushed (not polled) based
    /// on the capture — this REST poll is a placeholder until the real
    /// transport is confirmed.
    func pollSession(sessionId: String, token: String) async throws -> SessionInfo {
        throw BoosteroidClientError.notImplemented("pollSession — queue updates appear to be pushed, not polled; real transport unconfirmed")
    }

    /// CONFIRMED URL: GET /api/v1/streaming/user/last-session → 200. Likely
    /// used to detect/resume an in-progress session. Response shape unconfirmed.
    func getActiveSessions(token: String) async throws -> [ActiveSessionInfo] {
        let (data, response) = try await session.data(from: URL(string: "\(apiBase)/v1/streaming/user/last-session")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("getActiveSessions", String(data: data, encoding: .utf8) ?? "")
        }
        throw BoosteroidClientError.notImplemented("getActiveSessions — endpoint confirmed reachable, response decoding not yet written")
    }

    /// TODO(protocol): no `/webrtc/api/hangup`-style call was observed when
    /// ending a real session via the UI's "End Session" → confirm flow — the
    /// fetch-level capture used here didn't catch it, so it may go out over
    /// XHR, `navigator.sendBeacon`, or the same unconfirmed WebSocket used for
    /// queue updates. Needs a dedicated capture pass.
    func stopSession(sessionId: String, token: String) async throws {
        throw BoosteroidClientError.notImplemented("stopSession — teardown call not isolated in the capture yet")
    }
}

enum BoosteroidClientError: Error, LocalizedError {
    case notImplemented(String)
    case requestFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let detail):
            return "Not implemented yet: \(detail)"
        case .requestFailed(let name, let body):
            return "\(name) failed: \(body)"
        }
    }
}
