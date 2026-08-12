import SwiftUI
import GameController

struct MainTabView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    @State private var selectedGame: GameInfo?
    @State private var pendingGameToPlay: GameInfo?
    @State private var selectedTab: AppTab = .home

    private enum AppTab: Hashable {
        case home, library, settings, help
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView(
                    featuredGame: viewModel.lastPlayedGame ?? viewModel.library.first,
                    favoriteGames: viewModel.favoriteGames,
                    isLoading: viewModel.isLoading,
                    error: viewModel.error,
                    onPlay: launch,
                    onShowDetails: { selectedGame = $0 },
                    onRefresh: { await viewModel.refreshLibrary(authManager: authManager) }
                )
            }

            Tab("Library", systemImage: "books.vertical.fill", value: AppTab.library) {
                LibraryView(
                    games: viewModel.library,
                    isLoading: viewModel.isLoading,
                    onPlay: launch
                )
            }

            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }

            Tab("Help", systemImage: "questionmark.circle.fill", value: AppTab.help) {
                HelpView()
            }
        }
        .tint(BoosteroidTheme.violet)
        .background {
            ControllerTabSwitcher(
                isEnabled: gameToPlay == nil && selectedGame == nil,
                onPrevious: { moveTab(by: -1) },
                onNext: { moveTab(by: 1) }
            )
        }
        .environment(viewModel)
        .task { await viewModel.load(authManager: authManager) }
        .onChange(of: viewModel.streamSettings) { viewModel.saveSettings() }
        .fullScreenCover(item: $gameToPlay) { game in
            StreamView(game: game, settings: viewModel.streamSettings, onDismiss: { gameToPlay = nil })
                .environment(authManager)
                .environment(viewModel)
        }
        .fullScreenCover(item: $selectedGame, onDismiss: {
            guard let game = pendingGameToPlay else { return }
            pendingGameToPlay = nil
            launch(game)
        }) { game in
            GameOverviewView(
                game: game,
                isFavorite: viewModel.isFavorite(game),
                onPlay: {
                    pendingGameToPlay = game
                    selectedGame = nil
                },
                onToggleFavorite: { viewModel.toggleFavorite(game) },
                onDismiss: { selectedGame = nil }
            )
        }
    }

    private func launch(_ game: GameInfo) {
        viewModel.markPlayed(game)
        gameToPlay = game
    }

    private func moveTab(by offset: Int) {
        let tabs: [AppTab] = [.home, .library, .settings, .help]
        guard let current = tabs.firstIndex(of: selectedTab) else { return }
        let destination = current + offset
        guard tabs.indices.contains(destination) else { return }
        selectedTab = tabs[destination]
    }
}

/// Adds GeForce NOW-style bumper navigation without changing the normal tvOS
/// focus engine. It remains installed as controllers connect and ignores input
/// while an overview or streaming screen is presented.
private struct ControllerTabSwitcher: UIViewControllerRepresentable {
    let isEnabled: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onPrevious: onPrevious, onNext: onNext)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        context.coordinator.start()
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
        context.coordinator.installHandlers()
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var isEnabled: Bool
        var onPrevious: () -> Void
        var onNext: () -> Void
        private var connectObserver: NSObjectProtocol?

        init(isEnabled: Bool, onPrevious: @escaping () -> Void, onNext: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onPrevious = onPrevious
            self.onNext = onNext
        }

        func start() {
            connectObserver = NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                self?.installHandlers(on: controller)
            }
            installHandlers()
        }

        func installHandlers() {
            GCController.controllers().forEach(installHandlers)
        }

        private func installHandlers(on controller: GCController) {
            guard let gamepad = controller.extendedGamepad else { return }
            gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed, let self, self.isEnabled else { return }
                self.onPrevious()
            }
            gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed, let self, self.isEnabled else { return }
                self.onNext()
            }
        }

        func stop() {
            if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
            connectObserver = nil
            for controller in GCController.controllers() {
                controller.extendedGamepad?.leftShoulder.pressedChangedHandler = nil
                controller.extendedGamepad?.rightShoulder.pressedChangedHandler = nil
            }
        }
    }
}
