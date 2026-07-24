import SwiftUI

/// BoosteroidClient.fetchLibrary is wired up (GET
/// /api/v1/boostore/applications/installed) as of 2026-07-22.
/// TODO(protocol): grow the same kind of "Continue Playing" / "Favorites"
/// rows CloudNow has now that real data is flowing.
struct HomeView: View {
    let games: [GameInfo]
    let onPlay: (GameInfo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Fixed brand header — pinned so it no longer scrolls away with the
            // grid (it used to be a navigationTitle inside the ScrollView).
            BrandHeader()
                .padding(.horizontal, 40)
                .padding(.top, 24)
                .padding(.bottom, 16)

            if games.isEmpty {
                ScrollView {
                    ContentUnavailableView(
                        "No games yet",
                        systemImage: "gamecontroller",
                        description: Text("Boosteroid's catalog API hasn't been wired up yet.")
                    )
                    .padding(.top, 120)
                }
            } else {
                ScrollView {
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
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
            }
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

// MARK: - Brand Header
//
// A pinned, drawn-in-SwiftUI wordmark (no image asset needed, so it stays
// razor-sharp at any tvOS scale): a gradient "boost" bolt badge next to a
// gradient wordmark. Purely decorative — not focusable — so it never steals
// focus from the game grid.
struct BrandHeader: View {
    private var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 1.0, green: 0.45, blue: 0.2),   // orange
                     Color(red: 0.95, green: 0.25, blue: 0.55),  // pink
                     Color(red: 0.5, green: 0.3, blue: 0.95)],   // purple
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(brandGradient)
                .frame(width: 68, height: 68)
                .overlay(
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color(red: 0.95, green: 0.25, blue: 0.55).opacity(0.5), radius: 16, y: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text("Boosteroid")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(brandGradient)
                Text("CLOUD GAMING ON APPLE TV")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
