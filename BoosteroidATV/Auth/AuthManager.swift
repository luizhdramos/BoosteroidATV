import BackgroundTasks
import Foundation
import Observation

// MARK: - Login Phase

enum LoginPhase: Equatable {
    case idle
    case awaitingWebLogin(url: URL)
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
        loginTask = Task {
            guard let url = URL(string: BoosteroidAuth.loginStartUrl) else {
                loginPhase = .failed("Invalid login URL.")
                return
            }
            loginPhase = .awaitingWebLogin(url: url)
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginPhase = .idle
    }

    /// Called by WebLoginCaptureView once it observes the post-login navigation
    /// and captures whatever cookies are available at that point.
    ///
    /// TODO(protocol): the capture view currently has no reliable signal for
    /// "login succeeded" (no known success URL/cookie name yet) — see
    /// WebLoginCaptureView.swift for the exact TODOs.
    func receivedWebLoginCookies(_ cookies: [String: String]) {
        loginTask?.cancel()
        loginTask = Task {
            loginPhase = .exchangingTokens
            do {
                let newSession = try await api.completeLogin(cookies: cookies)
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
