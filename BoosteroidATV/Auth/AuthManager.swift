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
            loginPhase = .failed("Couldn't find any cookies in that text. Use a cookie-export browser extension (e.g. \"Cookie-Editor\" → Export → JSON), the Application > Storage > Cookies table (select a row, Cmd/Ctrl+A, Cmd/Ctrl+C), or the full 'Cookie' request header from the Network tab, and paste it here.")
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

    /// Parses any of the three formats users actually end up pasting:
    ///  1. A raw `Cookie:` request-header-style string ("name1=value1;
    ///     name2=value2"), typically hand-selected from DevTools' Network >
    ///     Headers panel. Easy to under-select by accident on a long,
    ///     visually-wrapped value — see (2)/(3) for more reliable sources.
    ///  2. A copy-paste of Chrome's Application > Storage > Cookies table
    ///     (select all rows, Cmd+C) — tab-separated columns (Name, Value,
    ///     Domain, ...), one cookie per line.
    ///  3. A JSON array export from a cookie-management extension (e.g.
    ///     "Cookie-Editor") — objects with at least "name" and "value"
    ///     string fields. These extensions hold the browser's `cookies`
    ///     permission, which (unlike page/console JavaScript) CAN read
    ///     HttpOnly cookies — this is the most reliable, fully automatable
    ///     source of the three, since nothing is manually selected by hand.
    private static func parseCookieHeader(_ raw: String) -> [String: String] {
        if let jsonResult = parseCookieJSON(raw), !jsonResult.isEmpty {
            return jsonResult
        }
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

    /// Parses a JSON array of cookie objects (e.g. exported by the
    /// "Cookie-Editor" browser extension), reading only the "name"/"value"
    /// fields each entry needs and ignoring the rest (domain, path,
    /// expirationDate, httpOnly, secure, sameSite, ...). Returns nil (not an
    /// empty dict) if the input isn't a JSON array at all, so callers can
    /// fall through to the other formats.
    private static func parseCookieJSON(_ raw: String) -> [String: String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8) else { return nil }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var result: [String: String] = [:]
        for entry in array {
            guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty
            else { continue }
            if let value = entry["value"] as? String {
                result[name] = value
            } else if let number = entry["value"] as? NSNumber {
                result[name] = number.stringValue
            }
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
