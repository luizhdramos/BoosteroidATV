import CoreImage
import SwiftUI
import UIKit

/// Help content. Topics expand inline rather than pushing a detail screen —
/// each one is short enough that a push would be more navigation than the
/// content warrants, and inline keeps everything reachable with the Siri
/// Remote's d-pad alone.
///
/// Everything here describes behavior that actually exists in the app. The
/// original skeleton had two topics that never matched anything real
/// ("Steam Controller" — the app has a Steam OVERLAY button, not Steam
/// Controller support; "Specifications" — vague) and a Technical Support
/// section linking to a Discord and a Reddit that don't exist for this
/// project. Those were dropped rather than filled with invented content.
struct HelpView: View {
    @State private var expanded: Topic?

    private enum Topic: String, CaseIterable, Identifiable {
        case introduction = "Introduction"
        case gettingStarted = "Getting Started"
        case controlMethods = "Control Methods"
        case steam = "Steam Big Picture & Overlay"
        case duringGameplay = "During Gameplay"
        case configuration = "Configuration"
        case requirements = "Requirements & Limits"
        case troubleshooting = "Troubleshooting"

        var id: String { rawValue }

        /// One entry per paragraph. A leading "• " marks a bullet; the row
        /// renderer indents those and leaves everything else as body copy.
        var lines: [String] {
            switch self {
            case .introduction:
                return [
                    "BoosteroidATV is an unofficial, open-source Boosteroid client for Apple TV. It signs in to your Boosteroid account, lists the games in your library, and streams a session to your TV over WebRTC with full controller support.",
                    "It is not affiliated with, endorsed by, or supported by Boosteroid, and it needs your own active Boosteroid subscription.",
                ]
            case .gettingStarted:
                return [
                    "• Sign in with your Boosteroid email and password on the login screen. No browser or second device is needed.",
                    "• Pair a game controller in tvOS Settings → Remotes and Devices → Bluetooth.",
                    "• Pick a game from your library on the Home screen. The app queues a session, waits for a machine, and starts streaming on its own.",
                    "Launching a game resumes it directly if that same game is already running on your account.",
                ]
            case .controlMethods:
                return [
                    "• Game controller — MFi, Xbox, PlayStation, and Nintendo Switch pads. Buttons, triggers, sticks, and D-pad are all forwarded to the cloud PC.",
                    "• Siri Remote — navigates the app. During a stream, press Play/Pause to open the options bar.",
                    "• On-screen keyboard — open it from the options bar to type into launchers, logins, or in-game chat.",
                    "• Pointer mode — turns the Siri Remote touch surface into a mouse, for launchers and desktop UI that a gamepad can't reach.",
                ]
            case .steam:
                return [
                    "Sessions started from this app open Steam directly in Big Picture mode, the controller-friendly interface built for a TV.",
                    "The Steam Overlay button in the options bar sends Shift+Tab to the cloud PC — the standard Steam overlay shortcut. The overlay is drawn inside the stream itself, so once it opens, use your controller as you normally would.",
                ]
            case .duringGameplay:
                return [
                    "Press Play/Pause on the Siri Remote or your controller to open the options bar. Press it again to close.",
                    "• Disconnect — ends the cloud session and returns to the app.",
                    "• Keyboard — opens the on-screen keyboard.",
                    "• Pointer — uses the Siri Remote touch surface as a mouse.",
                    "• Steam Overlay — sends Shift+Tab to the cloud PC.",
                    "• Performance Overlay — shows live bitrate, frame rate, latency, packet loss, and which server you're on.",
                ]
            case .configuration:
                return [
                    "• Stream quality — resolution from 720p to 4K, and 30, 60, or 120 fps.",
                    "• Bitrate — automatic, or a manual ceiling if you'd rather cap it yourself.",
                    "• Controller — analog stick deadzone, plus rumble on/off and its intensity.",
                    "• Overlay — turns the performance overlay on by default.",
                    "• Region — allow connections to distant regions, and pick a preferred server location. Allowing distant regions widens the pool of machines but can add latency.",
                    "Quality and region changes take effect the next time you start a game, not mid-session.",
                ]
            case .requirements:
                return [
                    "• An Apple TV running tvOS 17 or later.",
                    "• An active, paid Boosteroid subscription.",
                    "• A strong 5 GHz Wi-Fi or wired connection, especially for 1080p60 and above.",
                    "Video is H.264 only. Boosteroid delivers H.265 and AV1 exclusively over its own native transport, which this app does not implement — so that's a service-side limit, not an Apple TV one.",
                ]
            case .troubleshooting:
                return [
                    "• Controller not responding — make sure the pad is paired in tvOS Settings → Remotes and Devices, not just powered on. If it still doesn't respond, disconnect and start the game again.",
                    "• Rumble not working — check that rumble is enabled in Settings. Some third-party pads running in a compatibility or Xbox emulation mode don't implement vibration at all, even though their buttons work fine.",
                    "• Bitrate drops while playing — the server lowers quality when it detects packet loss or rising latency. Turn on the performance overlay: if latency and packet loss climb alongside the bitrate, it's a network condition rather than the app.",
                    "• Long queue times — Boosteroid queues per region. Allowing distant regions in Settings gives you access to more machines.",
                    "• Black screen after connecting — disconnect and start the game again.",
                ]
            }
        }
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
                        topicRow(topic)
                    }
                }
                .frame(maxWidth: 900)

                supportSection
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
    private func topicRow(_ topic: Topic) -> some View {
        let isExpanded = expanded == topic

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded = isExpanded ? nil : topic
                }
            } label: {
                HStack {
                    Text(topic.rawValue)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .tint(.gray)

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(topic.lines.enumerated()), id: \.offset) { _, line in
                        if line.hasPrefix("• ") {
                            HStack(alignment: .top, spacing: 12) {
                                Text("•")
                                Text(String(line.dropFirst(2)))
                            }
                        } else {
                            Text(line)
                        }
                    }
                }
                .font(.system(size: 24))
                // Not .secondary: on the dark background that renders too dim
                // to read comfortably from a couch.
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .padding(.top, 12)
            }
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SUPPORT THE PROJECT")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 32) {
                // tvOS has no browser, so a tappable link would go nowhere —
                // a QR code is the only way to hand this URL off to a device
                // that can actually open it.
                if let qr = Self.donationQR {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Buy Me a Coffee")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("BoosteroidATV is free and open source. If it's useful to you, scan the code with your phone to support development.")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(Self.donationURL)
                        .font(.system(size: 20, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private static let donationURL = "https://www.buymeacoffee.com/luizhdramos"

    /// Rendered once (static stored properties are lazy) rather than on every
    /// body evaluation — CoreImage rasterization is far too expensive to
    /// repeat on each SwiftUI update.
    private static let donationQR: UIImage? = makeQRCode(from: donationURL)

    private static func makeQRCode(from string: String) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // Medium error correction — enough tolerance for a photo taken of a
        // TV screen at an angle without inflating the module count.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // CIQRCodeGenerator emits roughly one pixel per module (~25x25pt), so
        // it has to be scaled up here. Scaling at render time instead would
        // resample and blur the modules; the .interpolation(.none) on the
        // Image above keeps the enlarged result crisp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
