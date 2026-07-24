import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel

    private let resolutions: [(String, String)] = [
        ("720p", "1280x720"), ("1080p", "1920x1080"),
        ("1440p", "2560x1440"), ("4K", "3840x2160"),
    ]
    private let fpsOptions: [(String, Int)] = [("30", 30), ("60", 60), ("120", 120)]

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                Section("Stream Quality") {
                    OptionRow(title: "Resolution", options: resolutions,
                              selection: $viewModel.streamSettings.resolution)
                    OptionRow(title: "FPS", options: fpsOptions,
                              selection: $viewModel.streamSettings.fps)
                    HStack {
                        Text("Codec")
                        Spacer()
                        Text("H.264")
                            .foregroundStyle(.secondary)
                    }
                    Text("Higher resolution/FPS depend on your Boosteroid plan and connection. Codec is fixed to H.264: Boosteroid only streams H.264 or AV1, and Apple TV can't decode AV1 (and Boosteroid doesn't offer H.265/HEVC).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Controller") {
                    HStack {
                        Text("Deadzone: \(Int(viewModel.streamSettings.controllerDeadzone * 100))%")
                        Spacer()
                        Button {
                            viewModel.streamSettings.controllerDeadzone = max(0, viewModel.streamSettings.controllerDeadzone - 0.05)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        Button {
                            viewModel.streamSettings.controllerDeadzone = min(0.5, viewModel.streamSettings.controllerDeadzone + 0.05)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                    }
                }
                Section("Account") {
                    Button("Sign Out", role: .destructive) { authManager.logout() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// A tvOS-friendly single-choice selector: a label plus one focusable button
/// per option, the selected one highlighted. Avoids SwiftUI's `Picker`, whose
/// pushed selection screen renders blank inside a Form/TabView on tvOS.
private struct OptionRow<Value: Hashable>: View {
    let title: String
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer()
            ForEach(options, id: \.1) { label, value in
                Button(label) { selection = value }
                    .buttonStyle(.bordered)
                    .tint(selection == value ? .orange : .gray)
            }
        }
    }
}
