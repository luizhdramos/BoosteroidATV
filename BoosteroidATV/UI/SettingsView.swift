import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                Section("Stream Quality") {
                    Picker("Resolution", selection: $viewModel.streamSettings.resolution) {
                        Text("1280x720").tag("1280x720")
                        Text("1920x1080").tag("1920x1080")
                    }
                    Picker("FPS", selection: $viewModel.streamSettings.fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    Picker("Codec", selection: $viewModel.streamSettings.codec) {
                        ForEach(VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
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
