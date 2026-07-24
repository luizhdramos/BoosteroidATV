import SwiftUI

/// BoosteroidClient.fetchLibrary is wired up (GET
/// /api/v1/boostore/applications/installed) as of 2026-07-22.
/// TODO(protocol): grow the same kind of "Continue Playing" / "Favorites"
/// rows CloudNow has now that real data is flowing.
struct HomeView: View {
    let games: [GameInfo]
    let onPlay: (GameInfo) -> Void

    /// Vertical space the pinned header occupies — the grid is inset by this
    /// so its first row starts below the header, then scrolls up UNDER it.
    private let headerReserve: CGFloat = 124

    var body: some View {
        ZStack(alignment: .top) {
            BoosteroidTheme.background.ignoresSafeArea()

            // Content scrolls the full height and passes behind the header.
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
                                    VStack(alignment: .leading, spacing: 8) {
                                        coverArt(for: game)
                                            .aspectRatio(1, contentMode: .fit)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(game.title).font(.headline).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.card)
                            }
                        }
                    }
                }
                .padding(.top, headerReserve)
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }

            // Fade scrim: fills with the background at the very top and fades to
            // clear just below the header, so rows scrolling up dissolve under
            // the pinned header instead of being cut off at a hard edge.
            LinearGradient(
                colors: [BoosteroidTheme.background, BoosteroidTheme.background, BoosteroidTheme.background.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: headerReserve + 28)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)

            // The pinned header itself.
            BrandHeader()
                .padding(.horizontal, 40)
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    // Deep indigo/navy page background.
    static let background = Color(red: 0.055, green: 0.05, blue: 0.16)

    static let violet = Color(red: 0.49, green: 0.23, blue: 0.93)   // #7C3AED
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)   // #4F46E5
    static let blue   = Color(red: 0.23, green: 0.51, blue: 0.96)   // #3B82F6

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [violet, indigo, blue], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Brand Header
//
// A pinned, drawn-in-SwiftUI wordmark (no image asset needed, so it stays
// razor-sharp at any tvOS scale): a gradient "boost" bolt badge next to a
// gradient wordmark. Purely decorative — not focusable — so it never steals
// focus from the game grid.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(BoosteroidTheme.brandGradient)
                .frame(width: 68, height: 68)
                .overlay(
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(.white)
                )
                .shadow(color: BoosteroidTheme.indigo.opacity(0.55), radius: 16, y: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text("Boosteroid")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(BoosteroidTheme.brandGradient)
                Text("CLOUD GAMING ON APPLE TV")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
