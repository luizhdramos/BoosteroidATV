import BackgroundTasks
import Foundation
import Observation

// MARK: - Login Phase

enum LoginPhase: Equatable {
    case idle
    /// tvOS has no WebKit at all (confirmed — the framework isn't shipped on
    /// this platform, so there's no in-app browser to render Boosteroid's
    /// Cloudflare-Turnstile-gated login page). The user instead logs in on a
    /// real browser on another device and pastes the resulting `Cookie`
    /// request header back into the app — see LoginView's manual entry screen.
    case manualCookieEntry
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
        loginPhase = .manualCookieEntry
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginPhase = .idle
    }

    /// Called by LoginView's manual entry screen once the user pastes the
    /// `Cookie` request header value they copied from a real browser login
    /// (e.g. via their browser's dev tools Network tab). BoosteroidAuthAPI
    /// validates the cookies against GET /api/v1/user before accepting them.
    func submitCookieHeader(_ raw: String) {
        let cookies = Self.parseCookieHeader(raw)
        guard !cookies.isEmpty else {
            loginPhase = .failed("Couldn't find any cookies in that text. Copy the whole Application > Storage > Cookies table for cloud.boosteroid.com (select a row, Cmd/Ctrl+A, Cmd/Ctrl+C), or the full 'Cookie' request header value from the Network tab, and paste it here.")
            return
        }
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

    /// Parses either of the two formats users actually end up pasting:
    ///  1. A raw `Cookie:` request-header-style string ("name1=value1;
    ///     name2=value2"), typically hand-selected from DevTools' Network >
    ///     Headers panel. Easy to under-select by accident on a long,
    ///     visually-wrapped value — see (2) for a more reliable source.
    ///  2. A copy-paste of Chrome's Application > Storage > Cookies table
    ///     (select all rows, Cmd+C) — tab-separated columns (Name, Value,
    ///     Domain, ...), one cookie per line. This table shows every cookie,
    ///     including HttpOnly ones, and copying whole rows avoids the manual
    ///     text-selection mistakes format (1) is prone to.
    private static func parseCookieHeader(_ raw: String) -> [String: String] {
        if raw.contains("\t") {
            let tableResult = parseCookieTable(raw)
            if !tableResult.isEmpty { return tableResult }
        }

        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leftover "-H" flag if the whole curl argument got pasted.
        if cleaned.hasPrefix("-H") {
            cleaned = String(cleaned.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip a single layer of wrapping quotes (curl uses single quotes).
        if cleaned.count >= 2,
           let first = cleaned.first, let last = cleaned.last,
           (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        // Strip a leading "cookie:" / "Cookie:" header-name prefix.
        if let colonRange = cleaned.range(of: ":"),
           cleaned[cleaned.startIndex..<colonRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("cookie") == .orderedSame {
            cleaned = String(cleaned[colonRange.upperBound...])
        }

        var result: [String: String] = [:]
        let pairs = cleaned
            .replacingOccurrences(of: "\n", with: ";")
            .split(separator: ";")
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let trimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "'\""))
            let name = parts[0].trimmingCharacters(in: trimSet)
            let value = parts[1].trimmingCharacters(in: trimSet)
            guard !name.isEmpty, !value.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    /// Parses a tab-separated cookie table paste (Chrome's Application >
    /// Storage > Cookies panel, whole rows copied): one cookie per line, with
    /// Name and Value as the first two tab-separated columns. Skips a header
    /// row if one got selected along with the data.
    private static func parseCookieTable(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 2 else { continue }
            let name = columns[0].trimmingCharacters(in: .whitespaces)
            let value = columns[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty,
                  name.caseInsensitiveCompare("name") != .orderedSame
            else { continue }
            result[name] = value
        }
        return result
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
