import Foundation
import Observation

@Observable
class GamesViewModel {
    var library: [GameInfo] = []
    var activeSessions: [ActiveSessionInfo] = []
    var isLoading = false
    var error: String?

    var streamSettings: StreamSettings = StreamSettings()

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
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
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
            guard let session = sessions.first else {
                return LaunchCheck(canPlay: false, message: notRunningMessage(game))
            }
            if session.gameId == game.id {
                if session.status == "LI" {
                    return LaunchCheck(canPlay: true, message: nil)
                }
                // "EN" (or anything not-live) for THIS game = queued.
                return LaunchCheck(canPlay: false, message:
                    "\(game.title) is still in the queue. Wait for it to start running, then open it here to play.")
            }
            // A session exists, but for a DIFFERENT game.
            let stateWord = session.status == "LI" ? "running" : "in the queue"
            return LaunchCheck(canPlay: false, message:
                "Another game is currently \(stateWord). Finish or wait for it, then start \(game.title) on another device (e.g. your browser) and open it here once it's running.")
        } catch {
            return LaunchCheck(canPlay: false, message:
                "Couldn't check the session status: \(error.localizedDescription)")
        }
    }

    private func notRunningMessage(_ game: GameInfo) -> String {
        "\(game.title) isn't running yet. Start it on another device (e.g. your browser) first — once it's running, open it here to take over and play."
    }
}
