import Foundation
import Observation

@Observable
class GamesViewModel {
    var library: [GameInfo] = []
    var activeSessions: [ActiveSessionInfo] = []
    var isLoading = false
    var error: String?

    var streamSettings: StreamSettings = StreamSettings()

    // MARK: - Streaming Region Preference
    //
    // Mirrors the account settings at cloud.boosteroid.com/profile/account/
    // main — "Permitir ligação a regiões distantes" and "Localização de
    // servidor preferida" — CONFIRMED 2026-08-02 to be plain account-level
    // preferences (see BoosteroidClient's Streaming Regions section). Loaded
    // once in `load()`; SettingsView reads/writes these directly.
    var playgrounds: [BoosteroidPlayground] = []
    var allowDistantRegions: Bool = true
    var preferredPlaygroundId: Int? = nil
    var regionSettingsError: String?

    private let client = BoosteroidClient()

    init() {
        if let data = UserDefaults.standard.data(forKey: "boosteroid.streamSettings"),
           let settings = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            self.streamSettings = settings
        }
    }

    func load(authManager: AuthManager) async {
        isLoading = true
        error = nil
        do {
            let cookies = try await authManager.resolveCookies()
            library = try await client.fetchLibrary(cookies: cookies)
            activeSessions = (try? await client.getActiveSessions(cookies: cookies)) ?? []
            // Best-effort: Settings still works (just shows defaults) if
            // either of these fails, so neither is allowed to fail `load()`
            // as a whole the way the library fetch above does.
            playgrounds = (try? await client.fetchPlaygrounds(cookies: cookies)) ?? []
            if let pref = try? await client.fetchRegionPreference(cookies: cookies) {
                allowDistantRegions = pref.allowDistantRegions
                preferredPlaygroundId = pref.preferredPlaygroundId
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Writes "Permitir ligação a regiões distantes" — optimistic update,
    /// reverted if the PATCH fails (matching saveSettings' fire-and-forget
    /// style elsewhere, but this one's server-side so it needs a real
    /// success/failure path rather than just writing UserDefaults).
    func setAllowDistantRegions(_ allow: Bool, authManager: AuthManager) async {
        let previous = allowDistantRegions
        allowDistantRegions = allow
        regionSettingsError = nil
        do {
            let cookies = try await authManager.resolveCookies()
            try await client.setAllowDistantRegions(allow, cookies: cookies)
        } catch {
            allowDistantRegions = previous
            regionSettingsError = "Couldn't update: \(error.localizedDescription)"
        }
    }

    /// Writes "Localização de servidor preferida". `nil` = "Localização
    /// automática".
    func setPreferredPlayground(_ id: Int?, authManager: AuthManager) async {
        let previous = preferredPlaygroundId
        preferredPlaygroundId = id
        regionSettingsError = nil
        do {
            let cookies = try await authManager.resolveCookies()
            try await client.setPreferredPlayground(id, cookies: cookies)
        } catch {
            preferredPlaygroundId = previous
            regionSettingsError = "Couldn't update: \(error.localizedDescription)"
        }
    }

    /// Resolves a raw gateway host (e.g. `SessionInfo.nodeBaseUrl`, like
    /// "https://sp7.cloud.boosteroid.com:443") to the friendly playground
    /// name shown in the server picker, by matching hostnames — CONFIRMED
    /// both `/v1/streaming/playgrounds`' gateway addresses and
    /// `session/details`' `gw` use the exact same "<code>.cloud.
    /// boosteroid.com" host. Used by StreamView to show which server a
    /// session actually landed on. Returns nil if playgrounds haven't
    /// loaded yet or nothing matches.
    func playgroundName(forGatewayHost host: String) -> String? {
        guard let targetHost = URL(string: host)?.host else { return nil }
        for playground in playgrounds {
            for gateway in playground.gateways {
                if URL(string: gateway.address)?.host == targetHost {
                    return playground.displayName
                }
            }
        }
        return nil
    }

    func saveSettings() {
        let data = try? JSONEncoder().encode(streamSettings)
        UserDefaults.standard.set(data, forKey: "boosteroid.streamSettings")
    }
}
