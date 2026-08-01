import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    @State private var path = NavigationPath()
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

    /// Settings and Help are pushed screens, not tabs — there's no "Home"
    /// destination because Home is the implicit root of the stack. tvOS pops
    /// a pushed NavigationStack destination automatically when the Menu/"TV"
    /// remote button is pressed, which is exactly the "press TV to go back to
    /// Home" behavior requested — no extra handling needed.
    private enum Destination: Hashable {
        case settings
        case help
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                    .padding(.horizontal, 60)
                    // focusSection makes the bar a first-class focus target, so
                    // pressing up from anywhere in the content below reliably
                    // returns focus here.
                    .focusSection()

                HomeView(games: viewModel.library, onPlay: { launchAlert = .confirm($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Soft fade at the top (and a touch at the bottom) so content
                    // dissolves as it scrolls past the fixed bar instead of being
                    // cut off by a hard edge.
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
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .settings:
                    SettingsView()
                case .help:
                    HelpView()
                }
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
                // createSession resumes a session that's genuinely still running
                // (proven by session/details returning a gateway) and otherwise
                // queues a new one.
                Text("If this game is still running, you'll pick up where you left off — including a session open on another device, which will move here. Otherwise a new session starts and you may wait in a queue.")
            }
        }
    }

    /// "BoosteroidTV" wordmark (with a lightning-bolt logo) top-left, and
    /// Settings/Help pill buttons top-right. No "Home" entry — Home is this
    /// screen itself.
    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(BoosteroidTheme.brandGradient)
                Text("BoosteroidTV")
                    .foregroundStyle(.white)
            }
            .font(.title2.weight(.bold))

            Spacer()

            HStack(spacing: 24) {
                navPill("Settings", systemImage: "gearshape.fill") { path.append(Destination.settings) }
                navPill("Help", systemImage: "questionmark.circle.fill") { path.append(Destination.help) }
            }
        }
    }

    @ViewBuilder
    private func navPill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.bordered)
        .tint(.gray)
    }

    private var alertTitle: String {
        switch launchAlert {
        case .confirm(let game): return "Start \(game.title)?"
        case nil: return ""
        }
    }
}
