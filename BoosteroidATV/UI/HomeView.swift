import SwiftUI

/// BoosteroidClient.fetchLibrary is wired up (GET
/// /api/v1/boostore/applications/installed) as of 2026-07-22.
/// TODO(protocol): grow the same kind of "Continue Playing" / "Favorites"
/// rows CloudNow has now that real data is flowing.
struct HomeView: View {
    let games: [GameInfo]
    let onPlay: (GameInfo) -> Void

    var body: some View {
        // Just the scrolling grid — MainTabView provides the fixed top bar and
        // the page background.
        ScrollView {
            Group {
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
                                coverArt(for: game)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
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

// MARK: - Theme
//
// Purple → indigo → blue palette (placeholder for the user's "morado y azul"
// palette — swap these hexes for the exact ones once provided). Centralized so
// the header, background, and any future screens share one source of truth.
enum BoosteroidTheme {
    // Near-black neutral page background (~#0B0B0E) — lets the game covers pop
    // without competing with the purple/blue brand mark.
    static let background = Color(red: 0.043, green: 0.043, blue: 0.055)

    static let violet = Color(red: 0.49, green: 0.23, blue: 0.93)   // #7C3AED
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)   // #4F46E5
    static let blue   = Color(red: 0.23, green: 0.51, blue: 0.96)   // #3B82F6

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [violet, indigo, blue], startPoint: .leading, endPoint: .trailing)
    }
}
