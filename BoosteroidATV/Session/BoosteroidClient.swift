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
    // CONFIRMED 2026-07-22: GET /api/v1/user → 200 for an authenticated
    // (cookie) session, body {"data":{"id":<int>,"name":...,"email":...,
    // "avatar":...,...}}. `id` is also what BoosteroidAuthAPI.completeLogin
    // stores as AuthUser.userId (needed as the WebSocket's `uid` param — see
    // BoosteroidRealtimeClient) and what AuthManager.resolveRealtimeCredentials
    // returns.

    func fetchCurrentUser(cookies: [String: String]) async throws -> AuthUser {
        let url = URL(string: "\(apiBase)/v1/user")!
        let (data, response) = try await session.data(for: authenticatedRequest(url, cookies: cookies))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("fetchCurrentUser", String(data: data, encoding: .utf8) ?? "")
        }
        let dto = try JSONDecoder().decode(BoosteroidUserResponseDTO.self, from: data)
        return AuthUser(userId: String(dto.data.id), displayName: dto.data.name, email: dto.data.email, avatarUrl: dto.data.avatar, membershipTier: "unknown")
    }

    // MARK: Session Lifecycle
    //
    // CONFIRMED flow, real endpoints/bodies, END TO END — this was verified
    // by actually watching a real (paying-tier) account's queue drain from
    // ~53 to 0 over a few minutes and PRAGMATA become genuinely playable:
    //   1. POST /api/v2/streaming/session/enqueue  body: {"appId": <int>}
    //      → 204, no response body (starts the queue).
    //   2. GET /api/v1/streaming/user/last-session → 200
    //      {"data":{"sessionId":"<uuid>","appId":<int>,"status":"EN"}}
    //      while queued, flipping to `"status":"LI"` (CONFIRMED — "Live",
    //      presumably) once the session is genuinely active. This is where
    //      the sessionId comes from — enqueue's own response never carries
    //      one. NOTE: an EARLIER pass through this investigation saw
    //      last-session apparently "stuck" returning a stale, already
    //      timed-out session's data (appId 836) no matter how many fresh
    //      enqueue calls were made for a different app. That turned out to
    //      be specific to that one leftover session (probably orphaned by
    //      test enqueue/cancel calls made directly via fetch(), bypassing
    //      whatever the real "leave queue" UI flow does) — once a session
    //      genuinely went active, last-session correctly reflected it. This
    //      endpoint is reliable; don't reintroduce the WebSocket-based
    //      redesign that was drafted while this looked like a dead end.
    //   3. Once ready, the UI navigates to
    //      cloud.boosteroid.com/static/streaming/streaming.html?sessionId={uuid}
    //      which calls POST /api/v1/streaming/session/details?sessionId=...
    //      (CONFIRMED POST-only; GET → 405), whose CONFIRMED success body is
    //      {"data":{"gw":"https://sp7.cloud.boosteroid.com:443",
    //      "queryString":"<jwt>"}} — `gw` is exactly SessionInfo.nodeBaseUrl,
    //      confirmed by watching the real client's subsequent getIceServers/
    //      getParams/call/addIceCandidate/getIceCandidate calls land on
    //      exactly that host, matching SignalingClient.swift's existing URL
    //      patterns byte-for-byte. For an expired/idle session this instead
    //      returns HTTP 406 with a `{"data":{"code":"timeout",...}}` body
    //      (see BoosteroidSessionDetailsErrorDTO / .sessionTimedOut).
    //
    // Separately, real-time queue-POSITION push (the numeric "Posição na
    // fila" the web UI shows) was confirmed via static analysis of
    // Boosteroid's own Angular bundle (two live WebSocket-constructor
    // capture passes caught nothing — the connection opens app-wide, right
    // after login, before any page-script patch can run) to be a generic
    // WebSocket at wss://cloud.boosteroid.com/ws?uid=<id>&token=<jwt>,
    // separate from last-session entirely — see BoosteroidRealtimeClient.
    // last-session tells you WHEN to stop waiting; the WS is only needed if
    // you want to show the user a live number while they do.

    func createSession(_ request: SessionCreateRequest, cookies: [String: String]) async throws -> SessionInfo {
        // Standalone-first (CONFIRMED 2026-07-23): the app must stream its OWN
        // fresh session so it is the SOLE WebRTC negotiator. It must NOT "take
        // over" a session another device is already streaming: opening our
        // control socket on it switches devices mid-stream, and the media path
        // does not survive that (ICE connects but zero frames arrive — the
        // server never feeds the newly-switched peer). Enqueue always creates a
        // brand-new session (orphaning any other), which IS the clean "switch
        // to Apple TV" we want — the app then negotiates fresh with nobody to
        // disrupt. The one thing we resume is our OWN still-queued ("EN")
        // session for the same game, so re-tapping doesn't lose our place in
        // the queue. (An earlier pass attached to "LI" sessions to "take over";
        // that was the source of the black screen — see the control-socket
        // switch note in BoosteroidControlChannel.)
        if let dto = try? await fetchLastSessionDTO(cookies: cookies),
           dto.data.appId == Int(request.gameId), dto.data.status == "EN" {
            return SessionInfo(sessionId: dto.data.sessionId, nodeBaseUrl: nil, status: "EN")
        }
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
        let dto = try await fetchLastSessionDTO(cookies: cookies)
        return SessionInfo(sessionId: dto.data.sessionId, nodeBaseUrl: nil, status: dto.data.status)
    }

    private func fetchLastSessionDTO(cookies: [String: String]) async throws -> BoosteroidLastSessionDTO {
        let url = URL(string: "\(apiBase)/v1/streaming/user/last-session")!
        let (data, response) = try await session.data(for: authenticatedRequest(url, cookies: cookies))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoosteroidClientError.requestFailed("last-session", String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(BoosteroidLastSessionDTO.self, from: data)
    }

    /// Polls the confirmed-working last-session endpoint (see Session
    /// Lifecycle note above for why this replaces a WebSocket that couldn't
    /// be captured).
    func pollSession(sessionId: String, cookies: [String: String]) async throws -> SessionInfo {
        try await fetchLastSession(cookies: cookies)
    }

    /// CONFIRMED URL/method/error-shape/success-shape — see the Session
    /// Lifecycle note above and SessionInfo's doc comment.
    ///
    /// CONFIRMED 2026-07-22 (real device report): calling this RIGHT after
    /// another client (e.g. a browser) just claimed the same session can
    /// return HTTP 200 with an EMPTY body instead of the real JSON — this
    /// was surfacing as Swift's generic "the data couldn't be read because
    /// it is missing" decode error (exactly what JSONDecoder throws on
    /// zero-byte Data). A user retrying manually a few seconds later (close
    /// app, reopen) succeeded, which points at this being a transient
    /// eventual-consistency race on Boosteroid's backend right at the
    /// moment of claim, not a hard "second call always fails" rule — so
    /// this retries a couple of times on an empty 200 body before giving up,
    /// instead of making the user retry by hand.
    func fetchSessionDetails(sessionId: String, cookies: [String: String], retriesOnEmptyBody: Int = 3) async throws -> SessionInfo {
        let url = URL(string: "\(apiBase)/v1/streaming/session/details?sessionId=\(sessionId)")!
        var lastEmptyStatus = 0
        for attempt in 0...retriesOnEmptyBody {
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
            guard !data.isEmpty else {
                lastEmptyStatus = status
                if attempt < retriesOnEmptyBody {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                break
            }
            let dto = try JSONDecoder().decode(BoosteroidSessionDetailsSuccessDTO.self, from: data)
            // "LI" (presumably "Live") is the CONFIRMED real active-session
            // status string — see the Session Lifecycle note above — so
            // this reuses it rather than inventing a synthetic marker.
            // queryString is now actually used — see SessionInfo's doc
            // comment and BoosteroidControlChannel.
            return SessionInfo(sessionId: sessionId, nodeBaseUrl: dto.data.gw, status: "LI", queryString: dto.data.queryString)
        }
        throw BoosteroidClientError.requestFailed("session/details", "Got \(retriesOnEmptyBody + 1) consecutive empty responses (HTTP \(lastEmptyStatus)) — the session may have just been claimed by another device and hasn't settled yet. Try again in a moment.")
    }

    /// Orchestrates the full queue → active flow: enqueue, poll last-session
    /// until status moves from "EN" (queued) to "LI" (active — both CONFIRMED
    /// real values, see Session Lifecycle note) or the timeout elapses, then
    /// fetch session details. Mirrors CloudNow's GFN queue flow (poll
    /// indefinitely, 180s setup timeout) per this project's own conventions.
    /// `onPoll` fires once right after enqueue (attempt 0) and again after
    /// every subsequent poll — last-session has no numeric queue-position
    /// field (that's only in the WebSocket push, see BoosteroidRealtimeClient
    /// — StreamView drives the live position display from that separately),
    /// so this callback's `status` is what's actually available here.
    func createAndAwaitSession(
        _ request: SessionCreateRequest,
        cookies: [String: String],
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        timeoutSeconds: TimeInterval = 600,
        onPoll: (@MainActor @Sendable (SessionInfo, Int) -> Void)? = nil
    ) async throws -> SessionInfo {
        guard let appId = Int(request.gameId) else {
            throw BoosteroidClientError.requestFailed("createAndAwaitSession", "Invalid game id \(request.gameId)")
        }
        var current = try await createSession(request, cookies: cookies)
        await onPoll?(current, 0)
        // The VM may already be ready (no queue), in which case session/details
        // returns a gw straight away.
        if let ready = try await detailsIfReady(sessionId: current.sessionId, cookies: cookies) {
            return ready
        }
        // Otherwise wait out the queue. CONFIRMED 2026-07-23: while queued,
        // last-session stays "EN" and session/details returns 406 "timeout"
        // (that 406 IS the queued state for a fresh session, not an expiry);
        // when a machine is assigned, session/details flips to 200 + gw. We
        // poll for THAT — waiting for last-session to reach "LI" instead would
        // deadlock, since a session only goes "LI" once a client claims it, and
        // we don't claim (open the control socket) until after this returns.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var attempt = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            attempt += 1
            guard let dto = try? await fetchLastSessionDTO(cookies: cookies), dto.data.appId == appId else {
                continue
            }
            current = SessionInfo(sessionId: dto.data.sessionId, nodeBaseUrl: nil, status: dto.data.status)
            await onPoll?(current, attempt)
            if let ready = try await detailsIfReady(sessionId: dto.data.sessionId, cookies: cookies) {
                return ready
            }
        }
        throw BoosteroidClientError.requestFailed("createAndAwaitSession", "Still waiting for a free machine after \(Int(timeoutSeconds))s. The queue can be long — try again.")
    }

    /// Returns the ready `SessionInfo` (gw + queryString) when the VM is
    /// assigned (session/details → 200 with a gw), or nil when still queued
    /// (406 "timeout") or transiently empty — i.e. "not ready yet, keep
    /// waiting". Only a genuinely unexpected response throws.
    private func detailsIfReady(sessionId: String, cookies: [String: String]) async throws -> SessionInfo? {
        let url = URL(string: "\(apiBase)/v1/streaming/session/details?sessionId=\(sessionId)")!
        let req = authenticatedRequest(url, cookies: cookies, method: "POST")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 406 { return nil }                        // queued (or expired) — keep waiting
        guard status == 200, !data.isEmpty else { return nil } // settling — keep waiting
        guard let dto = try? JSONDecoder().decode(BoosteroidSessionDetailsSuccessDTO.self, from: data) else { return nil }
        return SessionInfo(sessionId: sessionId, nodeBaseUrl: dto.data.gw, status: "LI", queryString: dto.data.queryString)
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

    /// TODO(protocol): no teardown REST call was observed when ending a real
    /// session via the UI's "End Session" → "End session" confirm flow — this
    /// time checked at the CDP network-request level (not just page-script
    /// patches, which are known-unreliable here — see BoosteroidRealtimeClient),
    /// so its absence is a stronger signal: teardown most likely goes out over
    /// the same WebSocket used for queue-position push. Note also that
    /// last-session did NOT immediately reflect the ended state (still showed
    /// "LI" right after confirming "End Session") — don't rely on it to
    /// detect that a session you ended yourself has actually stopped.
    func stopSession(sessionId: String, cookies: [String: String]) async throws {
        throw BoosteroidClientError.notImplemented("stopSession — no REST teardown call found; likely goes out over the WebSocket used for queue updates (see BoosteroidRealtimeClient) — unconfirmed message shape")
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
    /// Thrown instead of silently trying to attach to (and risk killing) a
    /// session that's already live for the same game — see createSession's
    /// comment for why a second session/details fetch on an already-active
    /// session looked dangerous.
    case sessionAlreadyActiveElsewhere

    var errorDescription: String? {
        switch self {
        case .notImplemented(let detail):
            return "Not implemented yet: \(detail)"
        case .requestFailed(let name, let body):
            return "\(name) failed: \(body)"
        case .sessionTimedOut:
            return "Session timed out while waiting in queue. Please try again."
        case .sessionAlreadyActiveElsewhere:
            return "This game is already being streamed on another device. Close it there first, then try again here."
        }
    }
}
