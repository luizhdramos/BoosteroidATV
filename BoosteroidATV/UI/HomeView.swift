import SwiftUI

struct HomeView: View {
    let featuredGame: GameInfo?
    let favoriteGames: [GameInfo]
    let isLoading: Bool
    let error: String?
    let onPlay: (GameInfo) -> Void
    let onShowDetails: (GameInfo) -> Void
    let onRefresh: () async -> Void

    var body: some View {
        ZStack {
            BoosteroidTheme.background.ignoresSafeArea()

            if isLoading, featuredGame == nil {
                loadingView
            } else if featuredGame == nil {
                emptyView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 52) {
                        if let featuredGame { featuredBanner(featuredGame) }
                        favoritesShelf
                    }
                    .padding(.horizontal, 60)
                    .padding(.top, 42)
                    .padding(.bottom, 80)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func featuredBanner(_ game: GameInfo) -> some View {
        ZStack(alignment: .bottomLeading) {
            heroArtwork(for: game)
                .frame(maxWidth: .infinity)
                .frame(height: 420)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.08), .black.opacity(0.82)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 16) {
                Text(game.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 5)
                    .lineLimit(1)
                Button { onPlay(game) } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(BoosteroidTheme.violet)
            }
            .padding(40)
        }
        .focusSection()
    }

    private var favoritesShelf: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Favorites")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
            if favoriteGames.isEmpty {
                Label("Favorite games from the Library to see them here.", systemImage: "star")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 42)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(favoriteGames) { game in
                            GameCard(game: game, onPlay: onPlay)
                                .frame(width: 200)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 22) {
            ProgressView()
                .controlSize(.large)
            Text("Loading your Boosteroid library…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No games yet", systemImage: "gamecontroller")
        } description: {
            Text(error ?? "Install a game in Boosteroid, then choose Refresh.")
        } actions: {
            Button("Refresh") { Task { await onRefresh() } }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func artwork(for game: GameInfo) -> some View {
        if let urlString = game.boxArtUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder(for: game)
                }
            }
        } else {
            placeholder(for: game)
        }
    }

    @ViewBuilder
    private func heroArtwork(for game: GameInfo) -> some View {
        if let urlString = game.heroBannerUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder(for: game)
                }
            }
        } else {
            placeholder(for: game)
        }
    }

    private func placeholder(for game: GameInfo) -> some View {
        Rectangle()
            .fill(BoosteroidTheme.cardGradient)
            .overlay(Text(game.title).font(.headline).multilineTextAlignment(.center).padding())
    }
}

struct GameOverviewView: View {
    let game: GameInfo
    let isFavorite: Bool
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()

            ZStack(alignment: .bottomLeading) {
                heroArtwork
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.22),
                                .init(color: .black.opacity(0.18), location: 0.5),
                                .init(color: .black.opacity(0.92), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(game.title)
                            .font(.system(size: 54, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 6)
                            .lineLimit(2)

                        Label("In Library", systemImage: "checkmark.circle.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(BoosteroidTheme.accent)

                        HStack(spacing: 16) {
                            Button(action: onPlay) {
                                Label("Play", systemImage: "play.fill")
                                    .frame(minWidth: 120)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(BoosteroidTheme.violet)

                            Button(action: onToggleFavorite) {
                                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                      systemImage: isFavorite ? "star.fill" : "star")
                            }
                            .buttonStyle(.bordered)
                            .tint(.gray)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        Text("BOOSTEROID")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text("Cloud Gaming")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                }
                .padding(80)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.18), lineWidth: 1))
            .padding(.horizontal, 96)
            .padding(.vertical, 86)
        }
        .onExitCommand(perform: onDismiss)
    }

    @ViewBuilder
    private var heroArtwork: some View {
        if let value = game.heroBannerUrl, let url = URL(string: value) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    BoosteroidTheme.cardGradient
                }
            }
        } else {
            BoosteroidTheme.cardGradient
        }
    }
}

struct LibraryView: View {
    let games: [GameInfo]
    let isLoading: Bool
    let onPlay: (GameInfo) -> Void
    @Environment(GamesViewModel.self) private var viewModel
    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .default
    @State private var carouselRequest: LibraryCarouselRequest?

    private var filteredGames: [GameInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = games.filter { game in
            query.isEmpty || game.title.localizedCaseInsensitiveContains(query)
        }
        switch sortOrder {
        case .default: break
        case .titleAZ: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleZA: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .recentFirst:
            result.sort {
                if $0.id == viewModel.lastPlayedGameID { return true }
                if $1.id == viewModel.lastPlayedGameID { return false }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return result
    }

    var body: some View {
        ZStack {
            BoosteroidTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    libraryHeader

                    if filteredGames.isEmpty, !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 140)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40)], spacing: 40) {
                            ForEach(filteredGames) { game in
                                GameCard(game: game) { selected in
                                    carouselRequest = LibraryCarouselRequest(games: filteredGames, startId: selected.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 50)
            }

            if isLoading, games.isEmpty { ProgressView().controlSize(.large) }
        }
        .searchable(
            text: $searchText,
            prompt: Text(games.isEmpty ? "Loading library…" : "Search \(games.count) games")
        )
        .fullScreenCover(item: $carouselRequest) { request in
            LibraryCarouselView(request: request, onPlay: onPlay, onDismiss: { carouselRequest = nil })
                .environment(viewModel)
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 18) {
            Text("Library").font(.largeTitle.weight(.bold))
            Text("\(filteredGames.count) of \(games.count) games").foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        Label(order.rawValue, systemImage: sortOrder == order ? "checkmark" : "circle")
                    }
                }
            } label: {
                Label("Sort: \(sortOrder.rawValue)", systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(.bordered)
            .tint(.gray)
        }
    }
}

private enum LibrarySortOrder: String, CaseIterable {
    case `default` = "Default"
    case titleAZ = "A → Z"
    case titleZA = "Z → A"
    case recentFirst = "Recently Played"
}

private struct LibraryCarouselRequest: Identifiable {
    let id = UUID()
    let games: [GameInfo]
    let startId: String
}

private struct LibraryCarouselView: View {
    private enum ActionFocus: Hashable { case play, favorite }

    let request: LibraryCarouselRequest
    let onPlay: (GameInfo) -> Void
    let onDismiss: () -> Void
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentIndex: Int
    @State private var navigationDirection = 1
    @FocusState private var actionFocus: ActionFocus?

    init(request: LibraryCarouselRequest, onPlay: @escaping (GameInfo) -> Void, onDismiss: @escaping () -> Void) {
        self.request = request
        self.onPlay = onPlay
        self.onDismiss = onDismiss
        _currentIndex = State(initialValue: request.games.firstIndex { $0.id == request.startId } ?? 0)
    }

    private var game: GameInfo { request.games[currentIndex] }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.96).ignoresSafeArea()

                // Match GeForce Now's accordion geometry. GeometryReader uses
                // tvOS's inset safe area here, so the card deliberately extends
                // nearly to that frame's edges to occupy about 90% of the actual
                // television width, while retaining the neighboring previews.
                // A prior HStack clipped the artwork before assigning those
                // widths, allowing the full images to spill over each other.
                ZStack {
                    if currentIndex > 0 {
                        neighborCard(at: currentIndex - 1, alignment: .trailing)
                            .frame(width: geo.size.width * 0.11, height: geo.size.height)
                            .compositingGroup()
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            // Center-card half width (49%) + preview half
                            // width (5.5%) + a visible GeForce-style gutter.
                            .offset(x: -(geo.size.width * 0.545 + 24))
                    }

                    overviewCard(game)
                        .frame(width: geo.size.width * 0.98, height: geo.size.height)
                        .compositingGroup()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        }
                        .id(game.id)
                        .transition(cardTransition)
                        .zIndex(1)

                    if currentIndex + 1 < request.games.count {
                        neighborCard(at: currentIndex + 1, alignment: .leading)
                            .frame(width: geo.size.width * 0.11, height: geo.size.height)
                            .compositingGroup()
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .offset(x: geo.size.width * 0.545 + 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, geo.size.height * 0.035)
            }
        }
        .onMoveCommand { direction in
            switch (direction, actionFocus) {
            case (.right, .play):
                actionFocus = .favorite
            case (.left, .favorite):
                actionFocus = .play
            case (.left, .play), (.left, nil):
                if currentIndex > 0 { moveCard(by: -1) }
            case (.right, .favorite), (.right, nil):
                if currentIndex + 1 < request.games.count { moveCard(by: 1) }
            default:
                break
            }
        }
        .onExitCommand(perform: onDismiss)
        .defaultFocus($actionFocus, .play)
    }

    private var cardTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let incoming: Edge = navigationDirection > 0 ? .trailing : .leading
        let outgoing: Edge = navigationDirection > 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: incoming).combined(with: .opacity),
            removal: .move(edge: outgoing).combined(with: .opacity)
        )
    }

    private func moveCard(by offset: Int) {
        let destination = currentIndex + offset
        guard request.games.indices.contains(destination) else { return }
        navigationDirection = offset
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.38, dampingFraction: 0.84)) {
            currentIndex = destination
        }
        actionFocus = .play
    }

    @ViewBuilder private func neighborCard(at index: Int, alignment: Alignment) -> some View {
        if request.games.indices.contains(index) {
            carouselArtwork(request.games[index])
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        } else { Color.clear }
    }

    private func overviewCard(_ game: GameInfo) -> some View {
        ZStack(alignment: .bottomLeading) {
            carouselArtwork(game).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.25), .black.opacity(0.94)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(game.title).font(.system(size: 58, weight: .bold)).lineLimit(2)
                    if !game.genres.isEmpty {
                        Text(game.genres.prefix(6).joined(separator: "  ·  "))
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    if let summary = game.summary {
                        Text(summary)
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(3)
                            .frame(maxWidth: 700, alignment: .leading)
                    }
                    Label("In Library", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(BoosteroidTheme.accent)
                    HStack(spacing: 16) {
                        Button { onPlay(game) } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 28, weight: .medium))
                                .frame(minWidth: 110)
                        }
                            .buttonStyle(.borderedProminent).tint(BoosteroidTheme.violet)
                            .focused($actionFocus, equals: .play)
                        Button { viewModel.toggleFavorite(game) } label: {
                            Label(viewModel.isFavorite(game) ? "Remove from Favorites" : "Add to Favorites",
                                  systemImage: viewModel.isFavorite(game) ? "star.fill" : "star")
                                .font(.system(size: 28, weight: .medium))
                        }
                        .buttonStyle(.bordered).tint(.gray)
                        .focused($actionFocus, equals: .favorite)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 20) {
                    metadata("DEVELOPER", game.developer)
                    metadata("PUBLISHER", game.publisher)
                    metadata("RATING", game.rating)
                }
            }.padding(80)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder private func metadata(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .trailing, spacing: 3) {
                Text(label).font(.system(size: 20, weight: .bold)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 28)).foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder private func carouselArtwork(_ game: GameInfo) -> some View {
        if let value = game.heroBannerUrl, let url = URL(string: value) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
                else { BoosteroidTheme.cardGradient }
            }
        } else { BoosteroidTheme.cardGradient }
    }
}

private struct GameCard: View {
    let game: GameInfo
    let onPlay: (GameInfo) -> Void

    var body: some View {
        Button { onPlay(game) } label: {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    artwork
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.7), .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )
                }
                .overlay(alignment: .bottomLeading) {
                    Text(game.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.card)
        .aspectRatio(2 / 3, contentMode: .fit)
    }

    @ViewBuilder
    private var artwork: some View {
        if let value = game.boxArtUrl, let url = URL(string: value) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    bannerFallback
                case .empty:
                    placeholder
                @unknown default:
                    bannerFallback
                }
            }
        } else {
            bannerFallback
        }
    }

    @ViewBuilder
    private var bannerFallback: some View {
        if let value = game.heroBannerUrl, let url = URL(string: value) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(BoosteroidTheme.cardGradient)
            .overlay(Image(systemName: "gamecontroller.fill").font(.largeTitle))
    }
}

enum BoosteroidTheme {
    static let background = Color(red: 0.105, green: 0.115, blue: 0.13)
    static let violet = Color(red: 0.49, green: 0.23, blue: 0.93)
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)
    static let blue = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let accent = Color(red: 0.28, green: 0.92, blue: 0.38)

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [violet, indigo, blue], startPoint: .leading, endPoint: .trailing)
    }

    static var cardGradient: LinearGradient {
        LinearGradient(colors: [violet.opacity(0.7), indigo.opacity(0.7), blue.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
