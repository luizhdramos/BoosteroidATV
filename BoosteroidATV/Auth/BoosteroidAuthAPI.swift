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

    /// CONFIRMED 2026-07-27 by capturing the real Android TV app's traffic
    /// (Frida SSL-pinning bypass + mitmproxy — see tools/android-tv-capture/):
    /// a direct, Turnstile-free email/password login — exactly what that
    /// app's own "Sign in Manually" button does. Response body:
    /// {"data":{"user":{id,name,email,avatar,...},"access_token":"Bearer ...",
    /// "refresh_token":"...","expires_in":"yyyy-MM-dd HH:mm:ss",...}}, PLUS
    /// Set-Cookie headers for access_token/refresh_token/boosteroid_auth/
    /// boosteroid_session — the SAME cookies `completeLogin(cookies:)` above
    /// already expects from a manually-pasted export. So this is a strictly
    /// better way to obtain those cookies; BoosteroidClient's existing
    /// cookie-based REST calls need no changes at all.
    func login(email: String, password: String) async throws -> AuthSession {
        guard let url = URL(string: BoosteroidAuth.apiBaseUrl + "/api/v1/auth/login") else {
            throw AuthError.loginFailed("Invalid login endpoint URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // REAL FIRST ATTEMPT (2026-07-28) with only Content-Type/Accept set
        // failed: "something wrong with your data" — a generic-sounding
        // rejection, not a credentials error. The shared `session` above sets
        // a DESKTOP BROWSER User-Agent (needed elsewhere for cookie/Cloudflare
        // compatibility), which this endpoint's backend likely branches on to
        // decide whether to require a Turnstile token — a browser UA hitting
        // this Turnstile-free native-app route may simply get refused. These
        // headers override that per-request with the exact values captured
        // from the real Android TV app (see tools/android-tv-capture/), so
        // this call presents as that same recognized client. `device-info`
        // and `device-name` describe the ANDROID EMULATOR the capture ran on
        // (not a real tvOS device) — using them verbatim maximizes the odds
        // of matching a known-accepted signature; TODO(protocol): swap in
        // real Apple TV device info once it's confirmed these fields aren't
        // validated/pinned to a specific value.
        //
        // `x-nonce-17`: adding the OTHER headers above got past "something
        // wrong with your data" but then hit a real, specific 422 "we could
        // not find those credentials" (error_code 142299) with genuinely
        // correct credentials (confirmed working seconds later on the real
        // Android app with the exact same email/password). CONFIRMED
        // 2026-07-28 by capturing a SECOND, separate real login — made
        // significantly later than the first capture — that this header's
        // value is "18211" BOTH times. A real per-request nonce or signature
        // would differ between two logins made minutes apart; an identical
        // value both times means it's a fixed constant baked into this app
        // build (v.2.5.10.tv), not something computed per-call, and
        // apparently required (likely a WAF/gateway fingerprint check) even
        // though the request body/other headers alone weren't enough.
        request.setValue("18211", forHTTPHeaderField: "x-nonce-17")
        request.setValue("BoosteroidAndroidTVClient v.2.5.10.tv; Android 14; sdk_gphone64_arm64", forHTTPHeaderField: "User-Agent")
        request.setValue("emu64a sdk_gphone64_arm64 34", forHTTPHeaderField: "device-name")
        request.setValue("", forHTTPHeaderField: "device-uniq-id")
        request.setValue("en-US", forHTTPHeaderField: "accept-language")
        request.setValue(
            #"{"brand":"google","chip":" ","device":"emu64a","hardware":"ranchu","manufacturer":"Google","model":"sdk_gphone64_arm64","name":"UE1A.230829.050","product":"sdk_gphone64_arm64"}"#,
            forHTTPHeaderField: "device-info"
        )
        request.setValue("boosteroid_entrypoint_source=1;boosteroid_entrypoint_page=1", forHTTPHeaderField: "Cookie")
        let body: [String: Any] = [
            "client_id": BoosteroidAuth.clientId,
            "client_secret": BoosteroidAuth.clientSecret,
            "email": email,
            "password": password,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.loginFailed("Couldn't reach Boosteroid: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.loginFailed("No HTTP response.")
        }
        guard http.statusCode == 200 else {
            // DEBUG (2026-07-28): surfacing the FULL raw body — including
            // error_code/error_number, not just the human-readable message —
            // because two different real failures ("something wrong with
            // your data", then "we could not find those credentials" after
            // fixing headers) both need the numeric code to tell apart
            // "wrong password" from "wrong client_id/client_secret pairing"
            // from "missing required x-nonce-17" from something else
            // entirely. Once the real cause is confirmed, trim this back to
            // just the human message.
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
            throw AuthError.loginFailed("HTTP \(http.statusCode): \(bodyText)")
        }
        guard let dto = try? JSONDecoder().decode(BoosteroidLoginResponseDTO.self, from: data) else {
            let bodyPreview = String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8 body>"
            throw AuthError.loginFailed("Unexpected response shape from /api/v1/auth/login: \(bodyPreview)")
        }

        var cookies: [String: String] = [:]
        if let headerFields = http.allHeaderFields as? [String: String] {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url) {
                cookies[cookie.name] = cookie.value
            }
        }

        let user = AuthUser(
            userId: String(dto.data.user.id),
            displayName: dto.data.user.name,
            email: dto.data.user.email,
            avatarUrl: dto.data.user.avatar,
            membershipTier: "unknown"
        )
        let tokens = AuthTokens(
            accessToken: dto.data.accessToken,
            refreshToken: dto.data.refreshToken,
            sessionCookies: cookies.isEmpty ? nil : cookies,
            expiresAt: Self.parseExpiresIn(dto.data.expiresIn) ?? Date().addingTimeInterval(12 * 60 * 60)
        )
        return AuthSession(tokens: tokens, user: user)
    }

    /// `expires_in` is misleadingly named — CONFIRMED (live capture) it's an
    /// absolute "yyyy-MM-dd HH:mm:ss" timestamp (UTC, matching the response's
    /// own `Date` header), not a duration in seconds.
    private static func parseExpiresIn(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: raw)
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

/// CONFIRMED 2026-07-27 response shape for POST /api/v1/auth/login (captured
/// from the real Android TV app). Reuses BoosteroidUserResponseDTO.Payload's
/// shape for the nested user object (SessionState.swift) since it's the same
/// {id,name,email,avatar} fields as GET /api/v1/user.
private struct BoosteroidLoginResponseDTO: Decodable {
    struct DataDTO: Decodable {
        let user: BoosteroidUserResponseDTO.Payload
        let accessToken: String
        let refreshToken: String
        let expiresIn: String

        enum CodingKeys: String, CodingKey {
            case user
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }
    let data: DataDTO
}
