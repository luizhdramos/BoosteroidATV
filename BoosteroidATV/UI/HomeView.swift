import SwiftUI

/// TODO(protocol): once BoosteroidClient.fetchLibrary actually works, this
/// should grow the same kind of "Continue Playing" / "Favorites" rows CloudNow
/// has. Left intentionally simple until we have real data to shape the UI
/// around.
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
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.gray.opacity(0.3))
                                        .aspectRatio(3/4, contentMode: .fit)
                                        .overlay(Text(game.title).padding())
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
}
