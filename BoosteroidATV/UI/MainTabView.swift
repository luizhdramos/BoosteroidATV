import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    @State private var tab = 0
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
        // A custom, always-fixed top bar instead of the system TabView: on
        // tvOS the system tab bar minimizes/moves when you scroll down into
        // content, which we don't want. Here the bar is a sibling above the
        // content in a VStack, so it never moves; pressing up from the content
        // returns focus to it.
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                navButton("Home", systemImage: "house.fill", index: 0)
                navButton("Settings", systemImage: "gearshape.fill", index: 1)
            }
            .padding(.top, 24)
            .padding(.bottom, 12)

            Group {
                switch tab {
                case 0:
                    HomeView(games: viewModel.library, onPlay: { launchAlert = .confirm($0) })
                default:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BoosteroidTheme.background.ignoresSafeArea())
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

    @ViewBuilder
    private func navButton(_ title: String, systemImage: String, index: Int) -> some View {
        Button {
            tab = index
        } label: {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.bordered)
        .tint(tab == index ? .orange : .gray)
    }

    private var alertTitle: String {
        switch launchAlert {
        case .confirm(let game): return "Start \(game.title)?"
        case nil: return ""
        }
    }
}
