# BoosteroidATV

A native, open-source **tvOS** client for [Boosteroid](https://cloud.boosteroid.com) cloud gaming — play your Boosteroid library on an Apple TV with a real game controller, streamed over WebRTC.

![Platform](https://img.shields.io/badge/platform-tvOS%2017%2B-black)
![Language](https://img.shields.io/badge/Swift-5.9%2F6-orange)
![Transport](https://img.shields.io/badge/streaming-WebRTC%20(H.264)-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Status](https://img.shields.io/badge/status-experimental-yellow)

> **Unofficial project.** BoosteroidATV is an independent, community-built client. It is **not affiliated with, endorsed by, or supported by Boosteroid**. It talks to Boosteroid's service using the same web APIs the official web player uses, reverse-engineered from observed traffic. Use it with your own paid account, for personal and educational purposes.

---

## Overview

Boosteroid ships official apps for many platforms but not for Apple TV. BoosteroidATV fills that gap with a from-scratch native tvOS app that authenticates against your Boosteroid account, lists your library, and streams a running game session straight to your TV with full controller support — including working rumble.

It is built in the same spirit as its sibling project **[CloudNow](https://github.com/owenselles/CloudNow)** (a native GeForce NOW client for Apple TV): SwiftUI UI, `AVSampleBufferDisplayLayer` video rendering, and [`livekit/webrtc-xcframework`](https://github.com/livekit/webrtc-xcframework) as the WebRTC transport.

## Features

- **Native tvOS experience** — a single-screen SwiftUI Home built for the Siri Remote and a couch, with Settings and Help pushed as full-screen destinations.
- **Your Boosteroid library** — signs in with your account and lists the games in your library via Boosteroid's own catalog API.
- **WebRTC game streaming** — low-latency H.264 video/audio over the same per-session WebRTC path the official web client uses.
- **Full input support** — MFi / Xbox / PlayStation / Nintendo Switch game controllers, forwarded to the cloud PC over Boosteroid's control channel. Controller mapping (buttons, triggers, sticks, D-pad) is matched byte-for-byte to the official client.
- **Controller rumble** — real vibration via CoreHaptics/GameController, confirmed working end to end on real hardware (Nintendo Switch Pro Controller). Toggle on/off and pick an intensity (Automatic, Weak, Medium, Strong, Very Strong) in Settings. Whether rumble actually works depends on the controller: some third-party "compatibility mode" pads (e.g. clones running in an emulated Xbox mode) don't implement the vibration side of that mode even though buttons work fine — that's a controller/firmware limitation, not something the app can fix.
- **Server / region selection** — mirrors cloud.boosteroid.com's account settings: a toggle to allow connecting to distant regions, and a dropdown to pick a preferred server location (or Automatic). The server you actually connected to is shown while streaming.
- **Quality settings** — resolution (720p / 1080p / 1440p / 4K), frame rate (30 / 60 / 120 fps), automatic or manual bitrate, and an analog-stick deadzone slider.
- **Optional performance overlay** — a compact, opt-in HUD showing Stream FPS, Decode FPS, network latency, packet loss, codec + bitrate, and which server you're on.

## How it works

A Boosteroid game session moves through several stages, each backed by a real service endpoint:

1. **Authentication** — a direct email/password login (`POST /api/v1/auth/login`), the same request Boosteroid's own Android TV app makes from its "Sign in Manually" screen. No browser, no Cloudflare Turnstile challenge (that only gates the public web login page, not this API route), nothing to copy or paste — see [Signing in](#signing-in). The response sets the same session cookies the rest of the REST API relies on; the app stores everything in the Keychain and refreshes it automatically.
2. **Session lifecycle** — tapping a game enqueues a fresh session for it (or resumes it if that exact game is already live), waits in Boosteroid's queue if needed, and resolves the per-session gateway host once a machine is ready. Fully standalone — no other device involved.
3. **Control channel** — a dedicated JSON WebSocket claims the session for this device, receives its streaming configuration, gates the WebRTC start, and carries all controller input (including rumble coming back from the game).
4. **WebRTC media** — the client negotiates an SDP offer/answer with the session's node, trickles ICE candidates, then renders decoded frames through Metal-backed `AVSampleBufferDisplayLayer`.

The codebase is organized into five functional areas:

| Area | Key files | Responsibility |
| --- | --- | --- |
| **Auth** | `AuthManager`, `BoosteroidAuthAPI`, `AuthCore` | Email/password sign-in, token refresh, and Keychain storage |
| **Session** | `BoosteroidClient`, `BoosteroidRealtimeClient`, `SessionState` | Catalog, session lifecycle, region/server preferences, and the live queue-position feed |
| **Streaming** | `StreamController`, `BoosteroidControlChannel`, `SignalingClient`, `SDPMunger`, `InputSender` | Control channel, WebRTC signaling, SDP munging, controller input, and rumble |
| **Video** | `VideoSurfaceView` | Decoded-frame rendering |
| **UI** | `MainTabView`, `HomeView`, `SettingsView`, `HelpView`, `StreamView`, `LoginView` | SwiftUI screens |

Protocol details that don't fit in code comments — the full session/queue/WebRTC handoff, confirmed vs. inferred behavior, and notes for anyone porting this to another platform — live in [`docs/switch-port-handoff.md`](docs/switch-port-handoff.md).

## Requirements

- **Xcode 16 or newer**
- **tvOS 17+** target (an Apple TV device or the tvOS Simulator)
- [`livekit/webrtc-xcframework`](https://github.com/livekit/webrtc-xcframework) via Swift Package Manager — already referenced in the project; Xcode resolves it on first open
- An active, paid **Boosteroid** account

## Building

1. Clone the repository and open `BoosteroidATV.xcodeproj` in Xcode:
   ```sh
   git clone https://github.com/luizhdramos/BoosteroidATV.git
   cd BoosteroidATV
   open BoosteroidATV.xcodeproj
   ```
2. Let Swift Package Manager resolve the WebRTC dependency. If it fails, use **File → Packages → Reset Package Caches** then **Resolve Package Versions** (the xcframework is a large binary download and needs a working connection).
3. Configure signing: select the **BoosteroidATV** target → **Signing & Capabilities** and pick your own team (Automatic signing). See `Local.xcconfig.example` for an xcconfig-based alternative.
4. Select an Apple TV (or the tvOS Simulator) as the run destination and build & run (⌘R).

## Signing in

Type your email and password on the Apple TV — no browser, no second device. That's the first screen the app shows.

## Usage

**Launching a game.** Fully standalone — just select a game on your Apple TV. That enqueues a fresh session for it (waiting in Boosteroid's queue if needed), or resumes it directly if that exact game is already live on the account. No other device is needed to start or hand off a session.

**Controls.** Pair a game controller to your Apple TV in **Settings → Remotes and Devices → Bluetooth**. In-game, press **Play/Pause** on the Siri Remote or controller to open the pause bar (Resume / Leave Game).

**Settings.** Stream quality (resolution, fps, bitrate), controller deadzone and rumble, the performance overlay, and region/server preference all live in Settings, reachable from the Home screen's top-right pill. Region and quality changes take effect the next time a game is started.

## Status & limitations

This is an **experimental, reverse-engineered** client. The core loop — sign in, list library, launch a game standalone (fresh queue or resume), stream video/audio, and send controller input (including rumble) — has been verified end-to-end against a real, paying account. Known constraints:

- **H.264 only.** Boosteroid's WebRTC path only offers H.264. H.265/HEVC and AV1 are delivered exclusively over Boosteroid's native UDP transport, which this client does not implement. (Apple TV can decode HEVC, so this is a service-side limitation, not a device one.)
- **Session termination not yet confirmed.** The Disconnect button closes the local connection; whether it also reliably ends the session on Boosteroid's side hasn't been validated yet.
- **No catalog browsing yet.** Home shows your installed library as a grid; there's no search, store browsing, or "Continue Playing"/Favorites rows yet.
- **Help screen is a placeholder.** The topic list exists in the UI but has no content behind it yet.

## Roadmap

- Richer catalog browsing (store / search / carousels, Continue Playing / Favorites rows)
- Help screen content
- Community testing across more controller models, especially around rumble

## Contributing

Issues and pull requests are welcome — this is a reverse-engineered client with no official docs behind it, so real-device testing (different controllers, regions, network conditions) is especially valuable. If you're touching the streaming/protocol layer, `docs/switch-port-handoff.md` and the `CONFIRMED` / `TODO(protocol)` / `UNCONFIRMED` comments throughout `BoosteroidATV/Streaming` and `BoosteroidATV/Session` explain what's been verified against real traffic versus what's still a best guess.

## Support

If BoosteroidATV is useful to you, you can support development here:

<a href="https://www.buymeacoffee.com/luizhdramos" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 37px !important;width: 170px !important;box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;-webkit-box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;" ></a>

## Acknowledgements

- [`livekit/webrtc-xcframework`](https://github.com/livekit/webrtc-xcframework) — the WebRTC transport
- [webrtc-streamer](https://github.com/mpromonet/webrtc-streamer) — the open-source project whose REST signaling shape Boosteroid's media path mirrors
- **[CloudNow](https://github.com/owenselles/CloudNow)** — the sibling GeForce NOW tvOS client that this project's architecture follows

## License

BoosteroidATV's source code is released under the [MIT License](LICENSE).

## Legal

BoosteroidATV is an unofficial client provided as-is, without warranty, for personal and educational use. "Boosteroid" and all related trademarks belong to their respective owners; this project is not affiliated with or endorsed by Boosteroid, and the MIT license above covers this repository's own code only — it grants no rights to Boosteroid's trademarks, branding, or backend service.
