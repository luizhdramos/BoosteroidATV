import SwiftUI

/// Structural skeleton only — matches the reference design's layout (a
/// centered "Help" title, a list of topic rows, then a "Technical Support"
/// section with community links). Copy/content for each topic comes later;
/// for now selecting a row does nothing.
struct HelpView: View {
    private enum Topic: String, CaseIterable, Identifiable {
        case introduction = "Introduction"
        case gettingStarted = "Getting Started"
        case controlMethods = "Control Methods"
        case steamController = "Steam Controller"
        case duringGameplay = "During Gameplay"
        case configuration = "Configuration"
        case specifications = "Specifications"
        case troubleshooting = "Troubleshooting"

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                Text("Help")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 12)

                VStack(spacing: 16) {
                    ForEach(Topic.allCases) { topic in
                        topicRow(topic.rawValue)
                    }
                }
                .frame(maxWidth: 900)

                VStack(alignment: .leading, spacing: 16) {
                    Text("TECHNICAL SUPPORT")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 16) {
                        linkRow("Join us on Discord", systemImage: "bubble.left.and.bubble.right.fill")
                        linkRow("Find us on Reddit", systemImage: "person.3.fill")
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 60)
            .padding(.vertical, 24)
        }
        .background(BoosteroidTheme.background.ignoresSafeArea())
    }

    @ViewBuilder
    private func topicRow(_ title: String) -> some View {
        Button {
            // TODO: navigate to the topic's content once it's written.
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.bordered)
        .tint(.gray)
    }

    @ViewBuilder
    private func linkRow(_ title: String, systemImage: String) -> some View {
        Button {
            // TODO: open the real Discord/Reddit link once available.
        } label: {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(.gray)
    }
}
