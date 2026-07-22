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
                    VStack(alignment: .leading) {
                        Text("Deadzone: \(Int(viewModel.streamSettings.controllerDeadzone * 100))%")
                        Slider(value: $viewModel.streamSettings.controllerDeadzone, in: 0...0.5)
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
