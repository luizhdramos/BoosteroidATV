import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    /// Drives the single launch alert (confirmation OR the attach-only
    /// "can't start yet" message). One enum keeps it to a single `.alert`
    /// modifier, avoiding the tvOS gotcha where stacking two alerts on one
    /// view makes only one fire.
    @State private var launchAlert: LaunchAlert?
    /// True while checkLaunch's network call is in flight.
    @State private var isCheckingLaunch = false

    private enum LaunchAlert: Identifiable {
        case confirm(GameInfo)
        case message(String)

        var id: String {
            switch self {
            case .confirm(let game): return "confirm-\(game.id)"
            case .message(let text): return "message-\(text)"
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
                    Task { await confirmLaunch(game) }
                }
                Button("Cancel", role: .cancel) { launchAlert = nil }
            case .message:
                Button("OK", role: .cancel) { launchAlert = nil }
            }
        } message: { alert in
            switch alert {
            case .confirm:
                // Warns about Boosteroid's confirmed behavior: starting a game
                // while queued for a different one drops you from that queue.
                Text("If you're waiting in a queue for another game, starting this one will remove you from that queue.")
            case .message(let text):
                Text(text)
            }
        }
        .overlay {
            if isCheckingLaunch {
                ProgressView("Checking session…")
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var alertTitle: String {
        switch launchAlert {
        case .confirm(let game): return "Start \(game.title)?"
        case .message: return "Can't Start Yet"
        case nil: return ""
        }
    }

    /// After the user confirms, check whether the game is already running and
    /// only then open the player — otherwise surface a clear message. The app
    /// can currently only attach to a live session (see
    /// GamesViewModel.checkLaunch).
    private func confirmLaunch(_ game: GameInfo) async {
        isCheckingLaunch = true
        let check = await viewModel.checkLaunch(game: game, authManager: authManager)
        isCheckingLaunch = false
        if check.canPlay {
            gameToPlay = game
        } else {
            launchAlert = .message(check.message ?? "This game isn't running yet. Start it on another device first, then open it here.")
        }
    }
}
