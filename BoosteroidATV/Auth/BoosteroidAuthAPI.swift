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
//     TODO(protocol): a plain WKWebView should render Turnstile fine (it's
//     just an iframe), but this needs to be verified on an actual tvOS device
//     — Turnstile occasionally special-cases non-desktop user agents.
//   - After a successful login, the session is COOKIE-based: the dashboard at
//     /dashboard loads directly with no token visible in the URL or a JS
//     global we captured. GET /api/v1/user returns 200 for an authenticated
//     session (see BoosteroidClient.fetchCurrentUser) — good for validating
//     whatever cookies WebLoginCaptureView captures.
//   - TODO(protocol): exact cookie name(s) that matter, expiry, and refresh
//     behavior are still unknown — capture `document.cookie` (readable ones
//     only; anything HttpOnly won't show) or watch Set-Cookie response
//     headers during login to fill this in.
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

    /// Called once the embedded web login reports success (see WebLoginCaptureView).
    /// TODO(protocol): today this just wraps whatever cookies/tokens the capture
    /// step handed back — there is no real token exchange yet because we don't
    /// know if one exists.
    func completeLogin(cookies: [String: String]) async throws -> AuthSession {
        guard !cookies.isEmpty else {
            throw AuthError.loginFailed("No session cookies captured from web login.")
        }
        // TODO(protocol): replace with a real call to whatever endpoint returns the
        // logged-in user's profile (id, display name, email, plan/tier).
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

    /// TODO(protocol): no known refresh mechanism yet. Once cookies/tokens expire,
    /// AuthManager currently just forces the user back through the web login.
    func refresh(_ session: AuthSession) async throws -> AuthSession {
        throw AuthError.tokenRefreshFailed("No refresh mechanism known yet for Boosteroid — re-login required.")
    }
}
