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
        // disrupt. (An earlier pass attached to "LI" sessions to "take over";
        // that was the source of the black screen — see the control-socket
        // switch note in BoosteroidControlChannel.)
        //
        // CONFIRMED 2026-07-24 — why this no longer resumes an existing "EN"
        // session: `last-session` can sit on a stale/orphaned queued session
        // forever, and resuming it returned here WITHOUT calling enqueue. That
        // meant no real queue entry was ever created: the app showed "status:
        // EN" indefinitely, no `queues/state` push ever referenced that appId,
        // and nothing appeared in a browser session either — while OTHER games
        // (whose appId didn't match the stale one) enqueued normally and worked.
        // Reported and reproduced with eFootball, which had exactly such a
        // leftover session; the resume path made it permanently unlaunchable.
        //
        // So: always enqueue. Enqueue always creates a brand-new session and
        // orphans any other (CONFIRMED), which is also the clean "switch to
        // Apple TV" this app wants — it then negotiates fresh with nobody else
        // to disrupt. Trade-off: re-tapping a game while genuinely queued
        // starts a new queue entry rather than resuming your place. That's the
        // price of never getting stuck on a zombie session; a smarter version
        // could resume only when a live `queues/state` push confirms the
        // existing entry is real (see BoosteroidRealtimeClient).
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

    /// Claims the machine once the queue clears — THE step that turns a queued
    /// ("EN") session into a running one.
    ///
    /// CONFIRMED 2026-07-24 by reading the web client's own API map and service
    /// (`startStreamingSession(appId)` → POST `{apiURIv2}/streaming/session/start`
    /// with body `{"appId": <int>}`); its call site sits with the "your machine
    /// is ready" confirmation modal. This is exactly the confirmation the user
    /// clicks in the browser, and the app never sent it — which is why a queue
    /// could drain to the front and then sit at "EN" forever: nothing ever told
    /// the server we were there to take the machine.
    ///
    /// (An earlier pass concluded no such endpoint existed. That was wrong: the
    /// bundle builds every URL from template literals, so grepping for literal
    /// path strings found nothing.)
    ///
    /// Returns the HTTP status (0 on transport failure) plus a short body
    /// excerpt, so callers can SHOW what the claim actually did. Calling this
    /// before it's genuinely our turn is expected to fail, so the poll loop
    /// just retries on the next pass.
    ///
    /// Surfacing the status matters: "the queue drained but nothing started"
    /// looks identical whether this endpoint is right and simply not our turn,
    /// or wrong (404 = bad path/version, 401/403 = auth, 422 = bad body).
    /// `sessionToken` is REQUIRED (CONFIRMED: omitting it → 422 "The session
    /// token field is required"; sending the session UUID instead → 400). It
    /// arrives with the `queues/start` push — see
    /// BoosteroidRealtimeClient.Event.queueReady.
    @discardableResult
    func startStreamingSession(appId: Int, sessionToken: String?, cookies: [String: String]) async -> (status: Int, body: String) {
        let url = URL(string: "\(apiBase)/v2/streaming/session/start")!
        var req = authenticatedRequest(url, cookies: cookies, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["appId": appId]
        if let sessionToken { payload["sessionToken"] = sessionToken }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, response) = try? await session.data(for: req) else { return (0, "no response") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseBody = String(data: data.prefix(180), encoding: .utf8) ?? ""
        return (status, responseBody)
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
            // `gw` is optional now (see the DTO). Left nil when absent rather
            // than guessed from the gateway list — see detailsIfReady for why
            // guessing was actively harmful.
            return SessionInfo(sessionId: sessionId, nodeBaseUrl: dto.data.gwAddress, status: "LI", queryString: dto.data.queryString)
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
        // CONFIRMED THE HARD WAY 2026-07-24: polling last-session AND
        // session/details every 2s got the whole account rate-limited (HTTP 429
        // "Too many requests. Try again in 15min." — on a plain GET). The web
        // client does not poll like this: queue progress arrives over the
        // realtime socket (`queues/state`) and the "machine ready" moment over
        // `queues/start`. So REST polling here is only a slow safety net.
        // Escalating 429s (8min, then 15min, then 32min lockouts) traced back to
        // this loop's volume: at 15s it issued ~8 requests/min, so a 25-minute
        // queue alone was ~200 calls. While queued we now poll only as a slow
        // safety net — the realtime socket is the real signal — and only go
        // quick once a machine is actually being assigned.
        queuedPollIntervalNanoseconds: UInt64 = 60_000_000_000,
        setupPollIntervalNanoseconds: UInt64 = 3_000_000_000,
        setupTimeoutSeconds: TimeInterval = 180,
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
        //
        // NO overall timeout while genuinely queued: real queues can run far
        // longer than any fixed cap (a live example sat at position 132 with a
        // ~1500s ETA), and a blanket 10-minute limit made the app give up on a
        // queue that was progressing perfectly well. Instead, mirror the
        // documented intent: wait out the queue indefinitely (the user can
        // always cancel, which cancels this task), and only bound the SETUP
        // phase — once last-session stops reporting "EN", a machine is being
        // assigned and details should appear within setupTimeoutSeconds.
        var attempt = 0
        var setupDeadline: Date?
        // Slow while queued, quicker once a machine is being assigned. Keeping
        // the queued cadence slow is what stops us tripping the rate limiter on
        // long waits; the realtime socket is what actually notices progress.
        var interval = queuedPollIntervalNanoseconds
        while true {
            try await Task.sleep(nanoseconds: interval)
            attempt += 1
            // NOTE: this used to `guard ... else { continue }` on last-session
            // matching our appId, which silently skipped the rest of the loop —
            // including onPoll — whenever last-session came back empty or for
            // another game. The UI then showed only "Connecting…" with no
            // status at all (reported), and, worse, the claim below never ran.
            // Report every outcome instead.
            let dto = try? await fetchLastSessionDTO(cookies: cookies)
            if let dto, dto.data.appId == appId {
                current = SessionInfo(sessionId: dto.data.sessionId, nodeBaseUrl: nil, status: dto.data.status)
                await onPoll?(current, attempt)

                // details is the ONLY source of the gateway (CONFIRMED: a ready
                // session returns {queryString, gw}, gw a plain string). While
                // still queued it can only answer 406, so asking then is pure
                // waste — and waste is what triggered the rate-limit lockouts.
                // The no-queue case is already covered by the immediate check
                // before this loop, and the queued case by the status leaving
                // "EN" after the confirmation.
                if dto.data.status != "EN",
                   let ready = try await detailsIfReady(sessionId: dto.data.sessionId, cookies: cookies) {
                    return ready
                }

                if dto.data.status == "EN" {
                    setupDeadline = nil // Still queued — keep waiting, no deadline.
                    interval = queuedPollIntervalNanoseconds
                } else {
                    interval = setupPollIntervalNanoseconds
                    // Left the queue but details still aren't ready: bound this.
                    let deadline = setupDeadline ?? Date().addingTimeInterval(setupTimeoutSeconds)
                    setupDeadline = deadline
                    if Date() > deadline {
                        throw BoosteroidClientError.requestFailed(
                            "createAndAwaitSession",
                            "The queue cleared but the machine didn't finish setting up after \(Int(setupTimeoutSeconds))s. Try again."
                        )
                    }
                }
            } else {
                let status = dto == nil ? "no session yet" : "another game is queued"
                await onPoll?(SessionInfo(sessionId: current.sessionId, nodeBaseUrl: nil, status: status), attempt)
            }

            // NOTE: do NOT claim (POST session/start) from this loop. An earlier
            // pass retried the claim every 6s here and earned an HTTP 429
            // "too many requests, try again in 8 min" — that endpoint is not
            // meant to be polled. The web client calls it exactly once, when
            // the realtime socket pushes `queues/start` ("a machine is reserved
            // for you"). StreamView listens for that and claims once; see
            // BoosteroidRealtimeClient.Event.queueReady.
        }
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

        if let gw = dto.data.gwAddress, !gw.isEmpty {
            return SessionInfo(sessionId: sessionId, nodeBaseUrl: gw, status: "LI", queryString: dto.data.queryString)
        }
        // No `gw` yet → NOT ready. Keep waiting.
        //
        // An earlier pass filled the gap with the first `priority` entry from
        // /v1/streaming/gateways. That was a guess, and a bad one: the account
        // has 16 priority gateways (so0-so7, sp0-sp7), so it picked the right
        // machine about one time in sixteen and otherwise produced "control
        // channel failed … socket is not connected". A wrong host is worse than
        // waiting, so never guess — the host must come from `gw` here or from
        // the claim response (see StreamView.gatewayFromClaim).
        return nil
    }

    /// The account's gateway hosts, from `GET /v1/streaming/gateways`
    /// (CONFIRMED 2026-07-24). Entries flagged `priority` are the ones for the
    /// account's region. Parsed leniently (the payload has been seen both bare
    /// and wrapped in `data`).
    ///
    /// NOT used to pick a streaming host: the account has 16 priority gateways,
    /// so choosing one here is a 1-in-16 guess that breaks the control socket.
    /// Kept for region/zone display and as documentation of the endpoint.
    func preferredGateway(cookies: [String: String]) async -> String? {
        let url = URL(string: "\(apiBase)/v1/streaming/gateways")!
        let req = authenticatedRequest(url, cookies: cookies, method: "GET")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rows = (root as? [[String: Any]])
            ?? ((root as? [String: Any])?["data"] as? [[String: Any]])
            ?? []
        let gateways = rows.compactMap { row -> BoosteroidGateway? in
            guard let address = row["address"] as? String, !address.isEmpty else { return nil }
            return BoosteroidGateway(address: address, priority: (row["priority"] as? Bool) ?? false)
        }
        return (gateways.first { $0.priority } ?? gateways.first)?.address
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
