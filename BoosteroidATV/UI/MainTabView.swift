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
            // focusSection makes the bar a first-class focus target, so
            // pressing up from anywhere in the content below reliably returns
            // focus here. Without it, focus can get trapped in the content
            // (notably Settings' form) with no way back to the tabs.
            .focusSection()

            Group {
                switch tab {
                case 0:
                    HomeView(games: viewModel.library, onPlay: { launchAlert = .confirm($0) })
                default:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Soft fade at the top (and a touch at the bottom) so content
            // dissolves as it scrolls past the fixed bar instead of being cut
            // off by a hard edge.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.94),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
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
                // createSession resumes a session that's genuinely still running
                // (proven by session/details returning a gateway) and otherwise
                // queues a new one.
                Text("If this game is still running, you'll pick up where you left off — including a session open on another device, which will move here. Otherwise a new session starts and you may wait in a queue.")
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
