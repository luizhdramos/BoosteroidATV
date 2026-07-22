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
//   - TODO(protocol): exact cookie name(s) that matter, expiry, and refresh
//     behavior are still unknown — inspect Set-Cookie response headers during
//     a real login (e.g. via a local proxy) to fill this in. Until then we
//     store whatever the user pasted verbatim and re-validate on each launch.
//   - TODO(protocol): whether there's a dedicated userinfo/profile JSON
//     endpoint beyond GET /api/v1/user, and that endpoint's response shape,
//     is still unconfirmed.
actor BoosteroidAuthAPI {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": BoosteroidAuth.userAgent]
        config.httpCookieStorage = HTTPCookieStorage.shared
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
        request.setValue(Self.cookieHeaderValue(cookies), forHTTPHeaderField: "Cookie")
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw AuthError.loginFailed("Couldn't reach Boosteroid to validate the cookies: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.loginFailed("Boosteroid rejected the pasted cookies (GET /api/v1/user returned \(status)). Make sure you copied the Cookie header after fully logging in, and that the session hasn't expired.")
        }
        // TODO(protocol): replace with a real call to whatever endpoint returns the
        // logged-in user's profile (id, display name, email, plan/tier) — GET
        // /api/v1/user's response body shape is still unconfirmed.
        let user = AuthUser(
            userId: "unknown",
            displayName: "Boosteroid User",
            email: nil,
            avatarUrl: nil,
            membershipTier: "unknown"
        )
        let tokens = AuthTokens(
            accessToken: "",
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

    /// TODO(protocol): no known refresh mechanism yet. Once cookies/tokens expire,
    /// AuthManager currently just forces the user back through the web login.
    func refresh(_ session: AuthSession) async throws -> AuthSession {
        throw AuthError.tokenRefreshFailed("No refresh mechanism known yet for Boosteroid — re-login required.")
    }
}
