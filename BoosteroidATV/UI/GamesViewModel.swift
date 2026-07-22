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
            let token = try await authManager.resolveToken()
            library = try await client.fetchLibrary(token: token)
            activeSessions = (try? await client.getActiveSessions(token: token)) ?? []
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func saveSettings() {
        let data = try? JSONEncoder().encode(streamSettings)
        UserDefaults.standard.set(data, forKey: "boosteroid.streamSettings")
    }
}
