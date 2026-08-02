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

    // MARK: - Launch gating (attach-only)
    //
    // Per the confirmed protocol (see CLAUDE.md / BoosteroidControlChannel):
    // this app can currently only ATTACH to a session that is already running
    // ("LI") — it can't reliably drive a fresh session from the queue on its
    // own (that path needs more protocol work on how EN→LI is signalled). So
    // before opening the player, check last-session and only proceed when the
    // requested game is genuinely live; otherwise tell the user to start it
    // externally first, rather than opening the player onto a black screen.
    struct LaunchCheck {
        let canPlay: Bool
        /// Non-nil (user-facing) when `canPlay` is false.
        let message: String?
    }

    func checkLaunch(game: GameInfo, authManager: AuthManager) async -> LaunchCheck {
        do {
            let cookies = try await authManager.resolveCookies()
            // getActiveSessions reads GET /api/v1/streaming/user/last-session
            // (the single most-recent session for the account, any game).
            let sessions = (try? await client.getActiveSessions(cookies: cookies)) ?? []

            // ONLY a genuinely live ("LI") session counts. CONFIRMED (see
            // CLAUDE.md): last-session can sit on a stale/orphaned "EN"
            // (queued) record indefinitely even when the user started
            // nothing — so "EN" must NOT be surfaced as "a game is queued"
            // (that produced a confusing "another game is in the queue"
            // message when nothing was actually running). Treat anything
            // that isn't LI as "nothing is running".
            guard let live = sessions.first(where: { $0.status == "LI" }) else {
                return LaunchCheck(canPlay: false, message: noRunningSessionMessage(game))
            }
            if live.gameId == game.id {
                return LaunchCheck(canPlay: true, message: nil)
            }
            // A DIFFERENT game is genuinely running right now.
            return LaunchCheck(canPlay: false, message:
                "A different game is currently running on your account. Close that session first, then start \(game.title) on another device and open it here.")
        } catch {
            return LaunchCheck(canPlay: false, message:
                "Couldn't check the session status: \(error.localizedDescription)")
        }
    }

    private func noRunningSessionMessage(_ game: GameInfo) -> String {
        "No game is currently running. Start \(game.title) on another device (e.g. your browser) and wait until it's actually playing — then open it here to take over."
    }
}
