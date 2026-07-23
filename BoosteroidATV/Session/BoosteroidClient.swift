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

    /// Every /api/v1 and /api/v2 call needs this — CONFIRMED (both from the
    /// /api/v1/user 401 saga and from createSession/enqueue hitting the same
    /// "Unauthenticated." error until it was routed through this): the API is
    /// cookie-session authenticated, and needs Origin/Referer to match the
    /// real frontend for Laravel/Sanctum-style backends to honor that cookie
    /// session at all.
    private func authenticatedRequest(_ url: URL, cookies: [String: String], method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
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

    func fetchApplication(id: String, cookies: [String: String]) async throws -> GameInfo {
        // CONFIRMED URL. Presumably the same per-application shape as the
        // installed-list's entries (BoosteroidApplicationDTO) — TODO(protocol):
        // confirm, since this single-item response hasn't actually been
        // captured/decoded yet, just assumed.
        let url = URL(string: "\(apiBase)/v1/boostore/applications/\(id)")!
        let (data, response) = try await session.data(for: authenticatedRequest(url, cookies: cookies))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("fetchApplication", String(data: data, encoding: .utf8) ?? "")
        }
        let dto = try JSONDecoder().decode(BoosteroidApplicationDTO.self, from: data)
        return GameInfo(dto)
    }

    // MARK: Current User
    //
    // CONFIRMED: GET /api/v1/user returns 200 for an authenticated (cookie)
    // session — good liveness/validation check for AuthManager, but response
    // body shape unconfirmed.

    func fetchCurrentUser(cookies: [String: String]) async throws {
        let url = URL(string: "\(apiBase)/v1/user")!
        let (data, response) = try await session.data(for: authenticatedRequest(url, cookies: cookies))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("fetchCurrentUser", String(data: data, encoding: .utf8) ?? "")
        }
        // TODO(protocol): decode into AuthUser once the body shape is known.
    }

    // MARK: Session Lifecycle
    //
    // CONFIRMED flow, real endpoints and bodies, in order:
    //   1. POST /api/v2/streaming/session/enqueue  body: {"appId": <int>}
    //      → 204, no response body (starts the queue).
    //   2. GET /api/v1/streaming/user/last-session → 200
    //      {"data":{"sessionId":"<uuid>","appId":<int>,"status":"EN"}}
    //      — this, not enqueue's response, is where the sessionId comes from.
    //      Queue position is shown live in the UI with NO visible REST
    //      polling for it — two separate WebSocket-constructor capture
    //      passes caught zero connections despite the on-screen position
    //      visibly updating, which strongly suggests Boosteroid opens one
    //      long-lived WS/SSE connection at app-shell load time (before this
    //      kind of page-context script injection could ever patch it), not
    //      per-queue. Polling last-session is the pragmatic, confirmed-
    //      working substitute used below.
    //   3. Once ready, the UI navigates to
    //      cloud.boosteroid.com/static/streaming/streaming.html?sessionId={uuid}
    //      which calls POST /api/v1/streaming/session/details?sessionId=...
    //      (CONFIRMED POST-only; GET → 405). TODO(protocol): its SUCCESS body
    //      (should carry nodeBaseUrl) was never captured — every session
    //      observed in this investigation pass either sat in a climbing
    //      queue or had already timed out (confirmed 406 error shape, see
    //      BoosteroidSessionDetailsErrorDTO) before reaching active.

    func createSession(_ request: SessionCreateRequest, cookies: [String: String]) async throws -> SessionInfo {
        let url = URL(string: "\(apiBase)/v2/streaming/session/enqueue")!
        var req = authenticatedRequest(url, cookies: cookies, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // CONFIRMED 2026-07-22 via a real captured request body: just
        // {"appId": <int>} — camelCase, singular. (Earlier guesses of
        // "applicationId", "app_id", and a hedge sending both "app_id" and
        // "appId" together are no longer needed now that the real body has
        // actually been observed.)
        let appIdValue: Any = Int(request.gameId) ?? request.gameId
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["appId": appIdValue])
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
            throw BoosteroidClientError.requestFailed("createSession/enqueue", String(data: data, encoding: .utf8) ?? "")
        }
        return try await fetchLastSession(cookies: cookies)
    }

    /// CONFIRMED URL/shape: see the Session Lifecycle note above. Used both
    /// to discover the sessionId right after enqueue and to poll queue
    /// status thereafter (see pollSession).
    private func fetchLastSession(cookies: [String: String]) async throws -> SessionInfo {
        let url = URL(string: "\(apiBase)/v1/streaming/user/last-session")!
        let (data, response) = try await session.data(for: authenticatedRequest(url, cookies: cookies))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("last-session", String(data: data, encoding: .utf8) ?? "")
        }
        let dto = try JSONDecoder().decode(BoosteroidLastSessionDTO.self, from: data)
        return SessionInfo(sessionId: dto.data.sessionId, nodeBaseUrl: nil, status: dto.data.status)
    }

    /// Polls the confirmed-working last-session endpoint (see Session
    /// Lifecycle note above for why this replaces a WebSocket that couldn't
    /// be captured).
    func pollSession(sessionId: String, cookies: [String: String]) async throws -> SessionInfo {
        try await fetchLastSession(cookies: cookies)
    }

    /// CONFIRMED URL/method/error-shape — see the Session Lifecycle note
    /// above. TODO(protocol): the success body (should carry nodeBaseUrl)
    /// still isn't confirmed, so a successful 200 here still throws
    /// .notImplemented, isolated to exactly this one spot.
    func fetchSessionDetails(sessionId: String, cookies: [String: String]) async throws -> SessionInfo {
        let url = URL(string: "\(apiBase)/v1/streaming/session/details?sessionId=\(sessionId)")!
        let req = authenticatedRequest(url, cookies: cookies, method: "POST")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 406,
           let err = try? JSONDecoder().decode(BoosteroidSessionDetailsErrorDTO.self, from: data),
           err.data.code == "timeout" {
            throw BoosteroidClientError.sessionTimedOut
        }
        guard status == 200 else {
            throw BoosteroidClientError.requestFailed("session/details", String(data: data, encoding: .utf8) ?? "")
        }
        throw BoosteroidClientError.notImplemented(
            "session/details returned 200, but its success body shape (needed for SessionInfo.nodeBaseUrl) has never actually been captured — decode it here once a live session reaches active status."
        )
    }

    /// Orchestrates the full queue → active flow: enqueue, poll last-session
    /// until status moves away from "EN" (queued) or the timeout elapses,
    /// then fetch session details. TODO(protocol): the real "active/ready"
    /// status string is unconfirmed (see Session Lifecycle note) — this
    /// treats ANY status other than "EN" as "try session/details now", which
    /// will surface a clear error rather than hang silently if that guess is
    /// ever wrong. Mirrors CloudNow's GFN queue flow (poll indefinitely, 180s
    /// setup timeout) per this project's own conventions.
    /// `onPoll` fires once right after enqueue (attempt 0) and again after
    /// every subsequent poll, so callers can show *something* better than a
    /// silent spinner — the confirmed last-session shape has no numeric
    /// queue-position field (that's only shown in the web UI, pushed over
    /// the WebSocket this app can't capture — see Session lifecycle note),
    /// so all we can surface is the raw status string and how long we've
    /// been waiting.
    func createAndAwaitSession(
        _ request: SessionCreateRequest,
        cookies: [String: String],
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        timeoutSeconds: TimeInterval = 180,
        onPoll: (@MainActor @Sendable (SessionInfo, Int) -> Void)? = nil
    ) async throws -> SessionInfo {
        var current = try await createSession(request, cookies: cookies)
        await onPoll?(current, 0)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var attempt = 0
        while current.status == "EN", Date() < deadline {
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            current = try await pollSession(sessionId: current.sessionId, cookies: cookies)
            attempt += 1
            await onPoll?(current, attempt)
        }
        guard current.status != "EN" else {
            throw BoosteroidClientError.requestFailed("createAndAwaitSession", "Queue wait exceeded \(Int(timeoutSeconds))s — Boosteroid's free-tier queue position can climb as paying-tier users cut ahead, so this can happen even after a long wait. Try again later.")
        }
        return try await fetchSessionDetails(sessionId: current.sessionId, cookies: cookies)
    }

    /// CONFIRMED URL/shape (same last-session endpoint/DTO as above). Used
    /// to detect/resume an in-progress session.
    func getActiveSessions(cookies: [String: String]) async throws -> [ActiveSessionInfo] {
        let url = URL(string: "\(apiBase)/v1/streaming/user/last-session")!
        let (data, response) = try await session.data(for: authenticatedRequest(url, cookies: cookies))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("getActiveSessions", String(data: data, encoding: .utf8) ?? "")
        }
        let dto = try JSONDecoder().decode(BoosteroidLastSessionDTO.self, from: data)
        return [ActiveSessionInfo(sessionId: dto.data.sessionId, status: dto.data.status, gameId: String(dto.data.appId))]
    }

    /// TODO(protocol): no `/webrtc/api/hangup`-style call was observed when
    /// ending a real session via the UI's "End Session" → confirm flow — the
    /// fetch-level capture used here didn't catch it, so it may go out over
    /// XHR, `navigator.sendBeacon`, or the same unconfirmed WebSocket used for
    /// queue updates. Needs a dedicated capture pass.
    func stopSession(sessionId: String, cookies: [String: String]) async throws {
        throw BoosteroidClientError.notImplemented("stopSession — teardown call not isolated in the capture yet")
    }
}

enum BoosteroidClientError: Error, LocalizedError {
    case notImplemented(String)
    case requestFailed(String, String)
    /// CONFIRMED shape: session/details returns HTTP 406 with
    /// {"data":{"code":"timeout",...}} for a session that expired while
    /// queued/idle. Surfaced distinctly so the UI can show a clear
    /// "try again" message instead of a raw error body.
    case sessionTimedOut

    var errorDescription: String? {
        switch self {
        case .notImplemented(let detail):
            return "Not implemented yet: \(detail)"
        case .requestFailed(let name, let body):
            return "\(name) failed: \(body)"
        case .sessionTimedOut:
            return "Session timed out while waiting in queue. Please try again."
        }
    }
}
