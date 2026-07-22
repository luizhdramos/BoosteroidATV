import CryptoKit
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
enum BoosteroidAuth {
    /// CONFIRMED real entry point — offers Google OAuth or email/password.
    static let loginStartUrl = "https://cloud.boosteroid.com/auth/start"

    /// CONFIRMED — all REST endpoints observed so far (catalog, session
    /// lifecycle, user) live under this host. The WebRTC signaling calls
    /// during an active stream go to a DIFFERENT, per-session host instead
    /// (e.g. "sp0.cloud.boosteroid.com" — see SessionInfo.nodeBaseUrl).
    static let apiBaseUrl = "https://cloud.boosteroid.com"

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

// MARK: - PKCE Helpers
//
// Kept in case Boosteroid's login turns out to be a standard OAuth/OIDC
// authorization-code + PKCE flow (common for web-based cloud gaming logins).
// Unused until that's confirmed.

struct PKCE {
    let verifier: String
    let challenge: String

    static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(86)
        let verifierStr = String(verifier)
        let challengeData = SHA256.hash(data: Data(verifierStr.utf8))
        let challenge = Data(challengeData)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return PKCE(verifier: verifierStr, challenge: challenge)
    }
}

// MARK: - Keychain
//
// Generic secure storage for the persisted auth session. Protocol-agnostic —
// no changes needed once the real auth flow is confirmed.

enum KeychainService {
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

struct AuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    /// Raw cookies captured from the embedded web login, in case the API turns
    /// out to be cookie-session-based rather than bearer-token-based.
    var sessionCookies: [String: String]?
    var expiresAt: Date

    var isExpired: Bool { expiresAt < Date() }
    var isNearExpiry: Bool { expiresAt.timeIntervalSinceNow < 10 * 60 }
}

struct AuthUser: Codable {
    let userId: String
    let displayName: String
    let email: String?
    let avatarUrl: String?
    var membershipTier: String
}

struct AuthSession: Codable {
    var tokens: AuthTokens
    var user: AuthUser
}

// MARK: - Errors

enum AuthError: Error, LocalizedError {
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
