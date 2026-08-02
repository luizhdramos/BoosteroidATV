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
        // Plain ScrollView with hand-built sections instead of `Form`: on the
        // app's dark background Form's own chrome/section headers rendered
        // dark-on-dark and became unreadable. Explicit colors here guarantee
        // contrast. No navigation title either — the top bar already says
        // "Settings".
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                section("Stream Quality") {
                    OptionRow(title: "Resolution", options: resolutions,
                              selection: $viewModel.streamSettings.resolution)
                    OptionRow(title: "FPS", options: fpsOptions,
                              selection: $viewModel.streamSettings.fps)
                }
                section("Bitrate") {
                    Toggle("Automatic bitrate", isOn: $viewModel.streamSettings.automaticBitrate)
                    if !viewModel.streamSettings.automaticBitrate {
                        StepperRow(
                            title: "Max bitrate",
                            value: "\(viewModel.streamSettings.manualBitrateMbps) Mbps",
                            onDecrease: { viewModel.streamSettings.manualBitrateMbps -= 5 },
                            onIncrease: { viewModel.streamSettings.manualBitrateMbps += 5 }
                        )
                    }
                }
                section("Controller") {
                    StepperRow(
                        title: "Deadzone",
                        value: "\(Int(viewModel.streamSettings.controllerDeadzone * 100))%",
                        onDecrease: { viewModel.streamSettings.controllerDeadzone = max(0, viewModel.streamSettings.controllerDeadzone - 0.05) },
                        onIncrease: { viewModel.streamSettings.controllerDeadzone = min(0.5, viewModel.streamSettings.controllerDeadzone + 0.05) }
                    )
                    Toggle("Controller rumble", isOn: $viewModel.streamSettings.rumbleEnabled)
                    if viewModel.streamSettings.rumbleEnabled {
                        HStack(spacing: 16) {
                            Text("Rumble intensity")
                            Spacer()
                            // Menu dropdown, same reasoning as the region
                            // picker below: a row of buttons per option
                            // reads worse than a single dropdown once
                            // there's more than a couple of choices.
                            Menu {
                                ForEach(RumbleIntensity.allCases, id: \.self) { intensity in
                                    Button {
                                        viewModel.streamSettings.rumbleIntensity = intensity
                                    } label: {
                                        if viewModel.streamSettings.rumbleIntensity == intensity {
                                            Label(intensity.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(intensity.displayName)
                                        }
                                    }
                                }
                            } label: {
                                Label(viewModel.streamSettings.rumbleIntensity.displayName, systemImage: "chevron.up.chevron.down")
                            }
                            .buttonStyle(.bordered)
                            .tint(.gray)
                        }
                    }
                    Text("Takes effect the next time a game is started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                section("Overlay") {
                    Toggle("Performance overlay", isOn: $viewModel.streamSettings.showStatsOverlay)
                }
                section("Region") {
                    Toggle("Allow connection to distant regions", isOn: allowDistantRegionsBinding)
                    Text("When searching for available virtual machines, gain access to more VMs, but may experience disruptions or increased latency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let regionSettingsError = viewModel.regionSettingsError {
                        Text(regionSettingsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 16) {
                        Text("Preferred server location")
                        Spacer()
                        // A grid of ~24 buttons (one per playground) was
                        // unreadable — per feedback, a dropdown Menu (like
                        // the real account-settings page's own select)
                        // scales to any number of locations without eating
                        // half the screen. SwiftUI's Menu renders as a
                        // proper tvOS popover (unlike Picker's pushed
                        // destination, which the OptionRow doc comment
                        // above notes renders blank here), so this is safe
                        // where Picker wasn't.
                        Menu {
                            Button {
                                Task { await viewModel.setPreferredPlayground(nil, authManager: authManager) }
                            } label: {
                                if viewModel.preferredPlaygroundId == nil {
                                    Label("Automatic Location", systemImage: "checkmark")
                                } else {
                                    Text("Automatic Location")
                                }
                            }
                            ForEach(viewModel.playgrounds) { playground in
                                Button {
                                    Task { await viewModel.setPreferredPlayground(playground.id, authManager: authManager) }
                                } label: {
                                    if viewModel.preferredPlaygroundId == playground.id {
                                        Label(playground.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(playground.displayName)
                                    }
                                }
                            }
                        } label: {
                            Label(selectedPlaygroundLabel, systemImage: "chevron.up.chevron.down")
                        }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                    }
                    Text("This setting takes effect the next time a game is started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                section("Account") {
                    Button("Sign Out") { authManager.logout() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 60)
            .padding(.vertical, 24)
        }
    }

    /// Mirrors cloud.boosteroid.com/profile/account/main's "Permitir ligação
    /// a regiões distantes" toggle (see GamesViewModel.setAllowDistantRegions
    /// / BoosteroidClient's Streaming Regions section for the confirmed
    /// PATCH this drives). The write is async and server-side, so this is a
    /// custom Binding rather than a plain `$viewModel.foo` — the setter fires
    /// a Task instead of writing synchronously.
    private var allowDistantRegionsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.allowDistantRegions },
            set: { newValue in
                Task { await viewModel.setAllowDistantRegions(newValue, authManager: authManager) }
            }
        )
    }

    /// The Menu button's own label — the currently selected location's name,
    /// or "Automatic Location" while `preferredPlaygroundId` is nil.
    private var selectedPlaygroundLabel: String {
        guard let id = viewModel.preferredPlaygroundId else { return "Automatic Location" }
        return viewModel.playgrounds.first(where: { $0.id == id })?.displayName ?? "Automatic Location"
    }

    /// One titled settings group: a bright header over its rows on a subtle
    /// translucent card, so both stay legible on the dark page background.
    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(.secondary)
            // NOTE: deliberately no blanket .foregroundStyle(.white) here.
            // On tvOS a focused button/toggle fills white and the system
            // inverts its label to dark; forcing white would override that
            // inversion and render white-on-white. Plain labels set their own
            // color individually instead.
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// A tvOS value stepper: a label, a centered value, and bordered −/+ buttons.
/// tvOS has no `Slider`/`Stepper`, so this is the adjuster pattern. Bordered
/// buttons (same style as `OptionRow`) give a clear, high-contrast focus state
/// — unlike borderless icon buttons, whose symbol turns white and blends into
/// the surrounding white text when focused. Focus the − or + button and press
/// the select/click button to change the value (left/right moves between them).
private struct StepperRow: View {
    let title: String
    let value: String
    var onDecrease: () -> Void
    var onIncrease: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer()
            Button(action: onDecrease) {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 130)
                .multilineTextAlignment(.center)
            Button(action: onIncrease) {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
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
                    .tint(selection == value ? .white : .gray)
            }
        }
    }
}
