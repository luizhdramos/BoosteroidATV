import Foundation

// MARK: - Boosteroid Auth API
//
// CONFIRMED 2026-07-27/28 by capturing the real Android TV app's own traffic
// (Frida SSL-pinning bypass + mitmproxy — see tools/android-tv-capture/):
// a direct, Turnstile-free email/password login via POST /api/v1/auth/login
// — exactly what that app's own "Sign in Manually" screen does. This
// replaced an earlier browser-plus-cookie-paste flow entirely (tvOS ships no
// WebKit at all, so an in-app browser was never possible; the REST login
// below needs no browser either way).
//
// The response sets the SAME cookies (access_token, refresh_token,
// boosteroid_auth, boosteroid_session) the rest of the app's REST calls
// already rely on (see BoosteroidClient, which is cookie-session
// authenticated, not bearer-token authenticated — Origin/Referer matter
// there for Laravel/Sanctum-style cookie-session checks).
actor BoosteroidAuthAPI {
    // Ephemeral + httpShouldHandleCookies = false below: URLSession's default
    // behavior merges any cookies already sitting in HTTPCookieStorage.shared
    // into every request's Cookie header, on top of whatever we set manually.
    // An ephemeral session never touches the shared cookie jar, so exactly
    // (and only) the header we set is what gets sent.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": BoosteroidAuth.userAgent]
        return URLSession(configuration: config)
    }()

    /// CONFIRMED 2026-07-27 by capturing the real Android TV app's traffic
    /// (Frida SSL-pinning bypass + mitmproxy — see tools/android-tv-capture/):
    /// a direct, Turnstile-free email/password login — exactly what that
    /// app's own "Sign in Manually" button does. Response body:
    /// {"data":{"user":{id,name,email,avatar,...},"access_token":"Bearer ...",
    /// "refresh_token":"...","expires_in":"yyyy-MM-dd HH:mm:ss",...}}, PLUS
    /// Set-Cookie headers for access_token/refresh_token/boosteroid_auth/
    /// boosteroid_session — the same cookies BoosteroidClient's existing
    /// cookie-based REST calls already need, so nothing else changes.
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
            // fixing headers) both needed the numeric code to tell apart
            // "wrong password" from "wrong client_id/client_secret pairing"
            // from "missing required x-nonce-17" from something else
            // entirely. Now confirmed working end-to-end; kept as-is since a
            // full body is still more useful than a trimmed one for whatever
            // shows up next (expired account, wrong region, etc.).
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

    /// TODO(protocol): no known refresh mechanism yet. Once cookies/tokens expire,
    /// AuthManager currently just forces the user back through login().
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
