import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                Section {
                    Picker("Resolution", selection: $viewModel.streamSettings.resolution) {
                        Text("1280×720").tag("1280x720")
                        Text("1920×1080").tag("1920x1080")
                        Text("2560×1440").tag("2560x1440")
                        Text("3840×2160 (4K)").tag("3840x2160")
                    }
                    Picker("FPS", selection: $viewModel.streamSettings.fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                        Text("120").tag(120)
                    }
                    Picker("Codec", selection: $viewModel.streamSettings.codec) {
                        ForEach(VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                } header: {
                    Text("Stream Quality")
                } footer: {
                    Text("Higher resolution/FPS depend on your Boosteroid plan and connection. H.264 is the most compatible codec — switch back to it if a game shows a black screen on H.265 or AV1.")
                }
                Section("Controller") {
                    // Note: SwiftUI's Slider (and Stepper) are unavailable on
                    // tvOS — the platform has no drag/click gesture model for
                    // them. Use plain focusable buttons instead.
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
