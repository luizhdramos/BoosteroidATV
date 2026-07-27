import BackgroundTasks
import Foundation
import Observation

// MARK: - Login Phase

enum LoginPhase: Equatable {
    case idle
    /// CONFIRMED 2026-07-27/28 (captured the real Android TV app's traffic,
    /// including the required x-nonce-17 header): a direct email/password
    /// form — exactly what that app's own "Sign in Manually" button does
    /// (POST /api/v1/auth/login), no external browser or cookie export
    /// needed. See BoosteroidAuthAPI.login(email:password:).
    case credentialsEntry
    case exchangingTokens
    case failed(String)
}

// MARK: - AuthManager

@Observable
@MainActor
final class AuthManager {
    private(set) var session: AuthSession?
    private(set) var loginPhase: LoginPhase = .idle

    var isAuthenticated: Bool { session != nil }

    private let api = BoosteroidAuthAPI()
    private var loginTask: Task<Void, Never>?
    private var refreshTimer: Task<Void, Never>?

    private static let bgTaskID = "com.luizhdramos.BoosteroidATV.tokenRefresh"

    // MARK: Lifecycle

    func initialize() async {
        guard let stored = try? KeychainService.load(),
              let saved = try? JSONDecoder().decode(AuthSession.self, from: stored)
        else { return }
        session = saved
        scheduleProactiveRefresh()
        scheduleBackgroundRefresh()
    }

    // MARK: Login

    func login() {
        loginTask?.cancel()
        loginTask = nil
        loginPhase = .credentialsEntry
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginPhase = .idle
    }

    /// Called by LoginView's email/password form — the primary login path.
    /// See BoosteroidAuthAPI.login(email:password:) for the confirmed
    /// protocol (captured from the real Android TV app).
    func submitCredentials(email: String, password: String) {
        // Trim the email only — tvOS remote-driven text input can leave
        // stray leading/trailing whitespace, and unlike the password this is
        // never a legitimate part of the value. Password is passed through
        // untouched: a trailing space could genuinely be part of it.
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        loginTask?.cancel()
        loginTask = Task {
            loginPhase = .exchangingTokens
            do {
                let newSession = try await api.login(email: email, password: password)
                session = newSession
                scheduleProactiveRefresh()
                scheduleBackgroundRefresh()
                try persist(newSession)
                loginPhase = .idle
            } catch {
                loginPhase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Logout

    func logout() {
        refreshTimer?.cancel()
        session = nil
        loginPhase = .idle
        KeychainService.delete()
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }

    // MARK: Token Resolution

    /// Returns the best available credential for authenticated requests.
    /// TODO(protocol): returns the bearer access token if we ever get one; callers
    /// that need cookie-based auth instead should read `session?.tokens.sessionCookies`.
    func resolveToken() async throws -> String {
        guard var s = session else { throw AuthError.noSession }
        if s.tokens.isNearExpiry {
            s = try await refresh(session: s)
        }
        return s.tokens.accessToken
    }

    /// CONFIRMED (live testing): the /api/v1/* JSON API is cookie-session
    /// authenticated, not bearer-token authenticated (see BoosteroidAuthAPI's
    /// header comment) — callers hitting those endpoints (BoosteroidClient)
    /// need the full cookie set, not just resolveToken()'s bearer JWT.
    func resolveCookies() async throws -> [String: String] {
        guard var s = session else { throw AuthError.noSession }
        if s.tokens.isNearExpiry {
            s = try await refresh(session: s)
        }
        guard let cookies = s.tokens.sessionCookies, !cookies.isEmpty else {
            throw AuthError.noSession
        }
        return cookies
    }

    /// CONFIRMED 2026-07-22 via static analysis of Boosteroid's own bundle:
    /// the real-time WebSocket at wss://cloud.boosteroid.com/ws (see
    /// BoosteroidRealtimeClient) authenticates via `?uid=<numeric user
    /// id>&token=<raw JWT>` — the *raw* access token, without the "Bearer "
    /// prefix `resolveToken()`/`AuthTokens.accessToken` carries (that prefix
    /// is only meaningful for an HTTP Authorization header).
    ///
    /// BUG FIXED 2026-07-22: any session created before the login flow
    /// learned to decode GET /api/v1/user's real body (i.e. anyone who
    /// logged in and never logged out again) has `user.userId == "unknown"`
    /// persisted in Keychain forever — this silently broke the queue-
    /// position WebSocket (no visible error; StreamView just never showed a
    /// number) because `guard s.user.userId != "unknown"` used to just
    /// throw here. Now it backfills the real id via
    /// `BoosteroidClient.fetchCurrentUser` on demand and persists it, so
    /// existing installs self-heal without needing a fresh login.
    func resolveRealtimeCredentials() async throws -> (userId: String, token: String) {
        guard var s = session else { throw AuthError.noSession }
        if s.tokens.isNearExpiry {
            s = try await refresh(session: s)
        }
        if s.user.userId == "unknown" {
            guard let cookies = s.tokens.sessionCookies, !cookies.isEmpty else {
                throw AuthError.noSession
            }
            let user = try await BoosteroidClient().fetchCurrentUser(cookies: cookies)
            s.user = user
            session = s
            try? persist(s)
        }
        var token = s.tokens.accessToken
        if token.hasPrefix("Bearer ") {
            token = String(token.dropFirst("Bearer ".count))
        }
        return (s.user.userId, token)
    }

    // MARK: Private — Refresh

    private func refresh(session s: AuthSession) async throws -> AuthSession {
        do {
            let refreshed = try await api.refresh(s)
            session = refreshed
            try? persist(refreshed)
            return refreshed
        } catch {
            // No known refresh path yet — if the session is fully expired, force
            // re-login rather than silently failing on every subsequent call.
            if s.tokens.isExpired {
                print("[Auth] Session expired and no refresh mechanism available — clearing session")
                refreshTimer?.cancel()
                session = nil
                KeychainService.delete()
            }
            throw error
        }
    }

    private func scheduleProactiveRefresh() {
        refreshTimer?.cancel()
        guard let s = session else { return }
        let delay = s.tokens.expiresAt.timeIntervalSinceNow - (5 * 60)
        guard delay > 0 else { return }
        refreshTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self, let s = self.session else { return }
            _ = try? await self.refresh(session: s)
        }
    }

    func scheduleBackgroundRefresh() {
        guard let s = session else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
        request.earliestBeginDate = s.tokens.expiresAt.addingTimeInterval(-(5 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }

    private func persist(_ s: AuthSession) throws {
        let data = try JSONEncoder().encode(s)
        try KeychainService.save(data)
    }
}
