# BoosteroidATV

A native, open-source **tvOS** client for [Boosteroid](https://cloud.boosteroid.com) cloud gaming — play your Boosteroid library on an Apple TV with a real game controller, streamed over WebRTC.

![Platform](https://img.shields.io/badge/platform-tvOS%2017%2B-black)
![Language](https://img.shields.io/badge/Swift-5.9%2F6-orange)
![Transport](https://img.shields.io/badge/streaming-WebRTC%20(H.264)-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Status](https://img.shields.io/badge/status-experimental-yellow)

> **Unofficial project.** BoosteroidATV is an independent, community-built client. It is **not affiliated with, endorsed by, or supported by Boosteroid**. It talks to Boosteroid's service using the same APIs the official apps use. Use it with your own paid account, for personal and educational purposes.

---

## Overview

Boosteroid ships official apps for many platforms but not for Apple TV. BoosteroidATV fills that gap with a from-scratch native tvOS app that authenticates against your Boosteroid account, lists your library, and streams a running game session straight to your TV with full controller support — including working rumble.

It is built in the same spirit as its sibling project **[CloudNow](https://github.com/owenselles/CloudNow)**, a native GeForce NOW client for Apple TV.

## Features

- **Native tvOS experience** — built for the Siri Remote and a couch, not a ported web page.
- **Your Boosteroid library** — sign in with your account and your installed games are right there.
- **Low-latency streaming** — H.264 video and audio over WebRTC, the same path the official web client uses.
- **Full controller support** — MFi / Xbox / PlayStation / Nintendo Switch gamepads, with buttons, triggers, sticks and D-pad all mapped exactly as the official clients do.
- **Controller rumble** — with an on/off toggle and an intensity setting (Automatic, Weak, Medium, Strong, Very Strong). Some third-party pads running in a compatibility or Xbox emulation mode don't implement vibration at all, even though their buttons work fine; that's a controller limitation the app can't work around.
- **Server / region selection** — mirrors cloud.boosteroid.com's account settings: a toggle to allow connecting to distant regions, and a dropdown to pick a preferred server location (or Automatic). The server you actually connected to is shown while streaming.
- **Quality settings** — resolution (720p / 1080p / 1440p / 4K), frame rate (60 / 120 fps), automatic or manual bitrate, and an analog-stick deadzone slider.
- **Optional performance overlay** — a compact, opt-in HUD showing bitrate, stream FPS, network latency, and which server you're on.

## Requirements

- An Apple TV running **tvOS 17 or newer**
- An active, paid **Boosteroid** account
- A game controller (optional, but the Siri Remote alone isn't much fun)

## Installing

Grab the `.ipa` from the [latest release](../../releases/latest) and install it with a sideloading tool such as [Sideloadly](https://sideloadly.io), signing in with your own Apple ID.

A few things worth knowing before you start:

- The `.ipa` is unsigned on purpose — the sideloading tool signs it with your Apple ID as it installs.
- On an Apple TV without a USB port, sideloading works from **macOS only**. On the Apple TV, open **Settings → Remotes and Devices → Remote App and Devices** and leave that screen open so your Mac can find it.
- With a free Apple ID the app stops working after 7 days and has to be reinstalled. A paid Apple Developer Program membership extends that to a year.

Prefer to build it yourself? See [Building](#building).

## Building

Needs **Xcode 16 or newer**. The WebRTC dependency is already referenced in the project and Xcode resolves it on first open.

1. Clone the repository and open `BoosteroidATV.xcodeproj` in Xcode:
   ```sh
   git clone https://github.com/luizhdramos/BoosteroidATV.git
   cd BoosteroidATV
   open BoosteroidATV.xcodeproj
   ```
2. Let Swift Package Manager resolve the WebRTC dependency. If it fails, use **File → Packages → Reset Package Caches** then **Resolve Package Versions** (the xcframework is a large binary download and needs a working connection).
3. Configure signing: select the **BoosteroidATV** target → **Signing & Capabilities** and pick your own team (Automatic signing). See `Local.xcconfig.example` for an xcconfig-based alternative.
4. Select an Apple TV (or the tvOS Simulator) as the run destination and build & run (⌘R).

### Building a .ipa

To produce an installable package instead of running from Xcode:

```sh
./scripts/build-ipa.sh              # unsigned — for sideloading tools
DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build-ipa.sh --signed
```

The result lands in `build/BoosteroidATV-<version>.ipa`. Unsigned is the default, since sideloading tools sign the app with the end user's own Apple ID anyway.

## Signing in

Type your email and password on the Apple TV — no browser, no second device. That's the first screen the app shows.

If you created your Boosteroid account with "Continue with Google", it has no password and this won't work. Set one on cloud.boosteroid.com first, then sign in here with it.

## Usage

**Launching a game.** Fully standalone — just select a game on your Apple TV. That enqueues a fresh session for it (waiting in Boosteroid's queue if needed), or resumes it directly if that exact game is already live on the account. No other device is needed to start or hand off a session.

**Controls.** Pair a game controller to your Apple TV in **Settings → Remotes and Devices → Bluetooth**. In-game, press **Play/Pause** on the Siri Remote or controller to open the pause bar (Resume / Leave Game).

**Settings.** Stream quality (resolution, fps, bitrate), controller deadzone and rumble, the performance overlay, and region/server preference all live in Settings, reachable from the Home screen's top-right pill. Region and quality changes take effect the next time a game is started.

## Status & limitations

This is an **experimental** client. Signing in, launching a game, streaming, and controller input (including rumble) all work; these are the rough edges to expect:

- **H.264 only.** Boosteroid delivers H.265 and AV1 only over a transport this app doesn't implement, so streams are H.264. Apple TV can decode HEVC — this is a service-side limit, not a device one.
- **Disconnecting doesn't free the machine right away.** Boosteroid keeps your machine warm for a while after a session ends, so reconnecting soon after resumes the running game instead of starting fresh. The official clients behave the same way.
- **No catalog browsing yet.** Home shows your installed library as a grid; there's no search, store browsing, or "Continue Playing"/Favorites rows yet.

## Roadmap

- Richer catalog browsing (store / search / carousels, Continue Playing / Favorites rows)
- Community testing across more controller models, especially around rumble
- H.265/AV1 video — a large piece of work, since it needs a transport this app doesn't currently implement

## Contributing

Issues and pull requests are welcome. This is an independent client with no official documentation behind it, so real-device testing — different controllers, regions and network conditions — is especially valuable. If you're working on the streaming layer, the code comments mark what's been verified in practice versus what's still a best guess.

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
