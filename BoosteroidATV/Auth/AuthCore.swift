import Foundation
import Security

// MARK: - Constants
//
// CONFIRMED 2026-07-22 against real traffic. `loginStartUrl` and `apiBaseUrl`
// are both correct — no separate API host, everything lives under
// cloud.boosteroid.com. There is NO device-flow/QR+PIN option on this login
// page (unlike GFN) — it's email/password (behind a Cloudflare Turnstile
// challenge) or Google OAuth. See BoosteroidAuthAPI.swift for the full
// confirmed/unconfirmed breakdown.
nonisolated enum BoosteroidAuth {
    /// CONFIRMED real entry point — offers Google OAuth or email/password.
    static let loginStartUrl = "https://cloud.boosteroid.com/auth/start"

    /// CONFIRMED — all REST endpoints observed so far (catalog, session
    /// lifecycle, user) live under this host. The WebRTC signaling calls
    /// during an active stream go to a DIFFERENT, per-session host instead
    /// (e.g. "sp0.cloud.boosteroid.com" — see SessionInfo.nodeBaseUrl).
    static let apiBaseUrl = "https://cloud.boosteroid.com"

    /// CONFIRMED 2026-07-27 by capturing the official Android TV client's own
    /// traffic (Frida SSL-pinning bypass + mitmproxy). This is that app's own embedded
    /// OAuth-style client id/secret pair, identical across every install
    /// (client_id 6) — it is not a per-user secret. Boosteroid's own
    /// "Sign in Manually" screen uses exactly this pair against
    /// POST /api/v1/auth/login, a plain JSON REST endpoint with no
    /// Cloudflare Turnstile challenge (Turnstile only gates the
    /// browser-facing /auth/login page, not this API route) — see
    /// BoosteroidAuthAPI.login(email:password:).
    static let clientId = 6
    static let clientSecret = "CDYb8AnfFEeU3p4Rd1A3oGonxMJMe3TdWJwDWSsy"

    // NOTE: Cloudflare's `cf_clearance` cookie (and possibly Boosteroid's own
    // session check) is tied to the User-Agent that was active when the
    // cookies were issued. This must match whatever browser you actually used
    // to log in and copy the Cookie header from — if you logged in with a
    // different browser, change this string to match it (real 401s have been
    // traced to a Safari UA here being paired with Chrome-issued cookies).
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
}

// MARK: - Keychain
//
// Generic secure storage for the persisted auth session. Protocol-agnostic —
// no changes needed once the real auth flow is confirmed.

nonisolated enum KeychainService {
    private static let service = "com.luizhdramos.BoosteroidATV"
    private static let account = "boosteroid-auth-session"

    static func save(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func load() throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.loadFailed(status)
        }
        return data
    }

    static func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
    }
}

// MARK: - Session Models

nonisolated struct AuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    /// Raw cookies captured from the embedded web login, in case the API turns
    /// out to be cookie-session-based rather than bearer-token-based.
    var sessionCookies: [String: String]?
    var expiresAt: Date

    var isExpired: Bool { expiresAt < Date() }
    var isNearExpiry: Bool { expiresAt.timeIntervalSinceNow < 10 * 60 }
}

nonisolated struct AuthUser: Codable {
    let userId: String
    let displayName: String
    let email: String?
    let avatarUrl: String?
    var membershipTier: String
}

nonisolated struct AuthSession: Codable {
    var tokens: AuthTokens
    var user: AuthUser
}

// MARK: - Errors

nonisolated enum AuthError: Error, LocalizedError {
    case noAuthCode
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)
    case noSession
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAuthCode: return "No authorization code received."
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .tokenRefreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .noSession: return "No authenticated session."
        case .loginFailed(let msg): return "Login failed: \(msg)"
        }
    }
}
