import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    /// Drives the launch confirmation alert.
    @State private var launchAlert: LaunchAlert?

    private enum LaunchAlert: Identifiable {
        case confirm(GameInfo)

        var id: String {
            switch self {
            case .confirm(let game): return "confirm-\(game.id)"
            }
        }
    }

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView(games: viewModel.library, onPlay: { launchAlert = .confirm($0) })
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .environment(viewModel)
        .task { await viewModel.load(authManager: authManager) }
        .onChange(of: viewModel.streamSettings) { viewModel.saveSettings() }
        .fullScreenCover(item: $gameToPlay) { game in
            StreamView(game: game, settings: viewModel.streamSettings, onDismiss: { gameToPlay = nil })
                .environment(authManager)
                .environment(viewModel)
        }
        .alert(
            alertTitle,
            isPresented: Binding(get: { launchAlert != nil }, set: { if !$0 { launchAlert = nil } }),
            presenting: launchAlert
        ) { alert in
            switch alert {
            case .confirm(let game):
                Button("Start") {
                    launchAlert = nil
                    gameToPlay = game
                }
                Button("Cancel", role: .cancel) { launchAlert = nil }
            }
        } message: { alert in
            switch alert {
            case .confirm:
                // The app streams its own fresh session (see
                // BoosteroidClient.createSession) — so this starts a new session
                // (and may wait in a queue), and stops the game if it's open on
                // another device.
                Text("This starts a new session for this game (you may wait in a queue). If it's open on another device, that one will stop.")
            }
        }
    }

    private var alertTitle: String {
        switch launchAlert {
        case .confirm(let game): return "Start \(game.title)?"
        case nil: return ""
        }
    }
}
