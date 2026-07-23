import SwiftUI

/// BoosteroidClient.fetchLibrary is wired up (GET
/// /api/v1/boostore/applications/installed) as of 2026-07-22.
/// TODO(protocol): grow the same kind of "Continue Playing" / "Favorites"
/// rows CloudNow has now that real data is flowing.
struct HomeView: View {
    let games: [GameInfo]
    let onPlay: (GameInfo) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                if games.isEmpty {
                    ContentUnavailableView(
                        "No games yet",
                        systemImage: "gamecontroller",
                        description: Text("Boosteroid's catalog API hasn't been wired up yet.")
                    )
                    .padding(.top, 120)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 24)], spacing: 24) {
                        ForEach(games) { game in
                            Button { onPlay(game) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    coverArt(for: game)
                                        .aspectRatio(3/4, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(game.title).font(.headline).lineLimit(1)
                                }
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(40)
                }
            }
            .navigationTitle("Boosteroid")
        }
    }

    /// `GameInfo.boxArtUrl` (confirmed as the catalog's `bannerImage`/`icon`
    /// field) is a real, directly-loadable image URL — no auth/cookies
    /// needed to fetch it (same as any public CDN asset), so a plain
    /// AsyncImage works. Falls back to a solid placeholder while loading, on
    /// failure, or when a game has no art URL at all.
    @ViewBuilder
    private func coverArt(for game: GameInfo) -> some View {
        if let urlString = game.boxArtUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    placeholder(for: game)
                }
            }
        } else {
            placeholder(for: game)
        }
    }

    private func placeholder(for game: GameInfo) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.gray.opacity(0.3))
            .overlay(Text(game.title).padding())
    }
}
