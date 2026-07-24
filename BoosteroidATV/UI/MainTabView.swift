import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    @State private var selectedTab = 0
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
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: 0) {
                HomeView(games: viewModel.library, onPlay: { launchAlert = .confirm($0) })
            }
            Tab("Settings", systemImage: "gearshape.fill", value: 1) {
                SettingsView()
            }
        }
        // Pinned brand mark: an overlay on the TabView (not inside a tab's
        // scrolling content), so it stays fixed at the tab-bar height instead
        // of scrolling away with the games grid when tvOS collapses the tab
        // bar. Home only; decorative (never steals focus).
        .overlay(alignment: .topLeading) {
            if selectedTab == 0 {
                BrandHeader(compact: true)
                    .padding(.leading, 60)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
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
