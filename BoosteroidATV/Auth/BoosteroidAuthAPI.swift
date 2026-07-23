import Foundation

// MARK: - Boosteroid Auth API
//
// CONFIRMED 2026-07-22 by loading https://cloud.boosteroid.com/auth/start in a
// real browser and logging in:
//   - The login screen offers "Continuar com Google" (OAuth) OR email/password
//     ("Iniciar sessão com e-mail" / "Registar com e-mail").
//   - The email/password form (at /auth/login) is gated by a Cloudflare
//     Turnstile challenge (a `challenges.cloudflare.com` iframe loads before
//     the form is usable) — this is a real anti-bot check, not decorative.
//   - After a successful login, the session is COOKIE-based: the dashboard at
//     /dashboard loads directly with no token visible in the URL or a JS
//     global we captured. GET /api/v1/user returns 200 for an authenticated
//     session — used below to validate whatever cookies the user pastes in.
//   - CONFIRMED 2026-07-22 (build failure on real hardware/Xcode): tvOS does
//     not ship WebKit at all — no WKWebView, no SFSafariViewController, and
//     ASWebAuthenticationSession is explicitly API_UNAVAILABLE on tvOS. There
//     is no in-app browser possible, so this can never render Boosteroid's
//     Turnstile challenge itself. The login flow is now: user logs in on a
//     real browser on another device, then pastes the resulting `Cookie`
//     request header into LoginView's manual entry screen, which lands here.
//   - CONFIRMED 2026-07-22 (401 debugging, live in Chrome): a plain
//     `fetch('/api/v1/user', {credentials:'include'})` from the logged-in
//     dashboard tab returns 200 using cookies ALONE — no Authorization header
//     needed. The `access_token` cookie's `Bearer+<jwt>` value (a PHP/Laravel
//     urlencode() of "Bearer <jwt>") is sent as a belt-and-suspenders
//     Authorization header below anyway, but it is NOT what makes /api/v1/user
//     work; cookies are sufficient on their own from a real browser.
//   - The remaining, most likely gap between "real browser" and "our
//     URLSession request": browsers always attach `Origin` (and usually
//     `Referer`) for same-origin fetches, which Laravel/Sanctum-style APIs
//     commonly check to decide whether to honor cookie-session auth at all
//     for a given request. Send both explicitly below.
//   - TODO(protocol): exact cookie name(s) that matter, expiry, and refresh
//     behavior are still unknown — inspect Set-Cookie response headers during
//     a real login (e.g. via a local proxy) to fill this in. Until then we
//     store whatever the user pasted verbatim and re-validate on each launch.
//   - TODO(protocol): whether there's a dedicated userinfo/profile JSON
//     endpoint beyond GET /api/v1/user, and that endpoint's response shape,
//     is still unconfirmed.
actor BoosteroidAuthAPI {
    // Ephemeral + httpShouldHandleCookies = false below: URLSession's default
    // behavior merges any cookies already sitting in HTTPCookieStorage.shared
    // into every request's Cookie header, on top of whatever we set manually.
    // With a shared/default session that meant every retry compounded a
    // previous pasted cookie set with the new one into one giant, malformed
    // header — the likely cause of the 414 some users hit here. An ephemeral
    // session never touches the shared cookie jar, so exactly (and only) the
    // header we set below is what gets sent.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": BoosteroidAuth.userAgent]
        return URLSession(configuration: config)
    }()

    /// Called once the user pastes a `Cookie` header value captured from a
    /// real browser login (see LoginView's manual entry screen — tvOS has no
    /// WebKit, so there is no in-app browser to capture this automatically).
    /// Validates the cookies actually work before accepting them, since a
    /// hand-pasted value is easy to get wrong (partial copy, expired session).
    func completeLogin(cookies: [String: String]) async throws -> AuthSession {
        guard !cookies.isEmpty else {
            throw AuthError.loginFailed("No session cookies provided.")
        }
        guard let userURL = URL(string: BoosteroidAuth.apiBaseUrl + "/api/v1/user") else {
            throw AuthError.loginFailed("Invalid user endpoint URL.")
        }
        var request = URLRequest(url: userURL)
        request.httpShouldHandleCookies = false
        request.setValue(Self.cookieHeaderValue(cookies), forHTTPHeaderField: "Cookie")
        request.setValue(BoosteroidAuth.apiBaseUrl, forHTTPHeaderField: "Origin")
        request.setValue(BoosteroidAuth.apiBaseUrl + "/dashboard", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let bearerToken = Self.decodedAccessToken(from: cookies)
        if let bearerToken {
            request.setValue(bearerToken, forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.loginFailed("Couldn't reach Boosteroid to validate the cookies: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Surface the actual response body (truncated) and what we parsed
            // and sent, instead of just the status code — a Cloudflare
            // challenge page, an HTML error page, and a real Laravel JSON 401
            // all need very different fixes, and guessing blind past this
            // point has not been productive.
            let bodyPreview = String(data: data.prefix(400), encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
            let cookieNames = cookies.keys.sorted().joined(separator: ", ")
            throw AuthError.loginFailed("""
                Boosteroid rejected the pasted cookies (GET /api/v1/user returned \(status)).
                Parsed \(cookies.count) cookies: \(cookieNames)
                Response body: \(bodyPreview)
                """)
        }
        // CONFIRMED 2026-07-22 live: GET /api/v1/user's body shape is
        // {"data":{"id":<int>,"name":...,"email":...,"avatar":...,...}}.
        // `id` matters beyond just display — it's the numeric `uid` the real
        // web client sends as a WebSocket query param when connecting to
        // wss://cloud.boosteroid.com/ws (see BoosteroidRealtimeClient).
        let user: AuthUser
        if let dto = try? JSONDecoder().decode(BoosteroidUserResponseDTO.self, from: data) {
            user = AuthUser(
                userId: String(dto.data.id),
                displayName: dto.data.name,
                email: dto.data.email,
                avatarUrl: dto.data.avatar,
                membershipTier: "unknown"
            )
        } else {
            user = AuthUser(userId: "unknown", displayName: "Boosteroid User", email: nil, avatarUrl: nil, membershipTier: "unknown")
        }
        let tokens = AuthTokens(
            accessToken: bearerToken ?? "",
            refreshToken: nil,
            sessionCookies: cookies,
            // TODO(protocol): placeholder expiry — we don't know the real session
            // lifetime, so refresh logic can't do anything useful until we do.
            expiresAt: Date().addingTimeInterval(12 * 60 * 60)
        )
        return AuthSession(tokens: tokens, user: user)
    }

    private static func cookieHeaderValue(_ cookies: [String: String]) -> String {
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// Fetches a plain-text/JSON body from an arbitrary URL — used when the
    /// user pastes a link to a cookie export (iCloud Drive share, Gist raw
    /// URL, etc.) instead of the cookie text itself, since Apple TV's remote
    /// text input has been confirmed to truncate very long pastes but handles
    /// a short URL fine.
    func fetchText(from url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.loginFailed("Fetching that link returned HTTP \(status).")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AuthError.loginFailed("That link didn't return readable text.")
        }
        // Share-page links (iCloud Drive's "Copy Link", Dropbox's default
        // share link, etc.) often resolve to an HTML wrapper page that needs
        // JavaScript to actually load the file, not the file's raw content —
        // confirmed with an iCloud Drive link returning icloud.com's page
        // shell instead of the pasted JSON. Catch that early with a clear
        // message instead of a confusing "no cookies found" a step later.
        let looksLikeHTML = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("<!doctype") || text.contains("<html")
        guard !looksLikeHTML else {
            throw AuthError.loginFailed("That link returned a web page instead of your file's raw content (common with iCloud Drive/Dropbox share links, which need a browser to load). Use a direct/raw link instead — e.g. a GitHub Gist's 'Raw' button URL, or paste.ee.")
        }
        return text
    }

    /// The `access_token` cookie's value is a PHP/Laravel urlencode() of the
    /// literal string "Bearer <jwt>" — decode the "+"-for-space encoding back
    /// into a real `Authorization` header value.
    private static func decodedAccessToken(from cookies: [String: String]) -> String? {
        guard let raw = cookies["access_token"] else { return nil }
        return raw.replacingOccurrences(of: "+", with: " ")
    }

    /// TODO(protocol): no known refresh mechanism yet. Once cookies/tokens expire,
    /// AuthManager currently just forces the user back through the web login.
    func refresh(_ session: AuthSession) async throws -> AuthSession {
        throw AuthError.tokenRefreshFailed("No refresh mechanism known yet for Boosteroid — re-login required.")
    }
}
