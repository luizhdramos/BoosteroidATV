# CLAUDE.md

This file provides guidance to Claude when working with code in this repository.

## Project

**BoosteroidATV** is a native tvOS app — a from-scratch cloud gaming client for
[Boosteroid](https://cloud.boosteroid.com) on Apple TV, in the same spirit as the
sibling project **CloudNow** (a reverse-engineered GeForce NOW client — see
`../BoosteroidTV/CloudNow`). It streams games over WebRTC
using [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework)
as the transport.

## Status: core protocol confirmed, several gaps remain

As of 2026-07-22, real traffic was captured by logging into
https://cloud.boosteroid.com, launching eFootball, playing briefly, and ending
the session, using the Claude in Chrome network inspector. **The core shape of
the protocol is now confirmed and implemented** — this is no longer a blind
guess like GFN's protocol was for CloudNow at the start. Search for
`TODO(protocol):` to find what's still unconfirmed or inferred rather than
observed directly:

```
grep -rn "TODO(protocol)" BoosteroidATV/
```

### What's confirmed (implemented against real behavior)

- **Login** (`https://cloud.boosteroid.com/auth/start`): email/password (behind
  a Cloudflare Turnstile challenge) or Google OAuth. No device-flow/QR+PIN
  option, unlike GFN. Session is cookie-based — GET `/api/v1/user` returns 200
  once logged in. A successful login lands on `/dashboard` (confirmed,
  reliable success signal, now wired up in `WebLoginCaptureView`).
- **Catalog**: GET `/api/v1/boostore/applications/{id}` (small integer ids,
  e.g. `836` = eFootball) and GET `/api/v1/boostore/carousel?isSub=true` (hero
  banner). No distinct "list my library" call was observed — likely embedded
  in the dashboard's initial SSR payload.
- **Session lifecycle**:
  1. POST `/api/v2/streaming/session/enqueue` → 204, puts the account in a
     queue for a free VM (UI shows live "Posição na fila" — queue position —
     with no visible REST polling, so it's almost certainly pushed over a
     WebSocket that wasn't isolated in this pass).
  2. Once ready, the browser navigates to
     `cloud.boosteroid.com/static/streaming/streaming.html?sessionId={uuid}`.
  3. That page calls POST `/api/v1/streaming/session/details?sessionId=...`
     (200; presumed to return the per-node WebRTC host, response body
     unconfirmed).
  4. GET `/api/v1/streaming/user/last-session` exists for detecting a
     resumable session (response shape unconfirmed).
- **WebRTC signaling — the big find**: media negotiation happens against a
  **per-session node host** (confirmed real example: `sp0.cloud.boosteroid.com`)
  using a REST API matching the shape of the open-source
  [webrtc-streamer](https://github.com/mpromonet/webrtc-streamer) project
  (its `webrtcstreamer.js` is literally loaded by the page):
  - `GET {node}/webrtc/api/getIceServers?sessionId=...` — response captured
    verbatim: `{"iceServers":[{"credential":"...","urls":["turn:HOST:3478?transport=udp"],"username":"<unixSeconds>:boosteroid"}],"iceTransportPolicy":"all"}`
  - `GET {node}/webrtc/api/getParams?sessionId=...` — response captured
    verbatim: `{"codec":"H264","version":1}`
  - `POST {node}/webrtc/api/call?peerid={random}&sessionId=...` — client sends
    its SDP **offer** here (Boosteroid's client is the WebRTC offerer, unlike
    GFN where the server offers) and gets an answer back. Body/response shape
    inferred from the upstream OSS project's convention, NOT confirmed
    byte-for-byte (see TODOs in `SignalingClient.swift`).
  - `POST {node}/webrtc/api/addIceCandidate?peerid={random}&sessionId=...` —
    called once per locally-trickled ICE candidate (8 times in the capture).
  - `GET {node}/webrtc/api/getIceCandidate?peerid={random}&sessionId=...` —
    polls for remote ICE candidates (REST polling, not push).
  - `peerid` is a plain JS `Math.random()` value as a string (e.g.
    `"0.9150882553499954"`), not a UUID.
  - Codec confirmed H.264 for this session; whether H.265/AV1 are ever offered
    is unknown.
  - `janus.js` / `janus-helper.js` are also loaded by the page, but the media
    path clearly goes through the REST API above — Janus's role (if any) is
    unconfirmed, possibly unrelated features (chat, cursor overlay).
- **Session end**: clicking "End Session" → confirm shows a star-rating
  screen. No `/webrtc/api/hangup`-equivalent call was caught in a fetch-level
  capture — teardown likely goes over XHR, `sendBeacon`, or the same
  unconfirmed WebSocket used for queue updates.

### What's still unconfirmed (see inline `TODO(protocol):` comments)

- Exact request/response **bodies** for `/enqueue`, `/session/details`,
  `/webrtc/api/call`, and `/webrtc/api/addIceCandidate` — only the URLs,
  methods, and (for `getIceServers`/`getParams`) full response bodies were
  captured. Body capture was blocked for larger payloads by the browser
  tool's exfiltration-prevention filter (it refuses to return output shaped
  like a cookie/query-string blob or a base64 dump) — get these from a local
  proxy (e.g. mitmproxy on your own Mac) instead of in-tool JS dumps.
- The queue-position push transport (WebSocket URL/protocol).
- The session teardown/hangup call.
- Any data channel(s) for keyboard/mouse/controller input — a real session
  clearly accepted input (menu navigation, button presses worked in-game),
  but the transport for that wasn't isolated from the WebRTC media path.
- The catalog "list my library" endpoint (if it's not just SSR-embedded).
- Where exactly `SessionInfo.nodeBaseUrl` (e.g. `sp0.cloud.boosteroid.com`)
  comes from — presumably the `session/details` response.

## Building

- **Xcode 16+**, targeting tvOS 17+ (project settings currently pin tvOS 26.4 —
  adjust `TVOS_DEPLOYMENT_TARGET` down if building against an older SDK).
- Open `BoosteroidATV.xcodeproj` in Xcode and build/run via Xcode.
- **Required SPM dependency**: Add
  [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework)
  via Xcode → File → Add Package Dependencies before building (already
  referenced in the project file; Xcode should resolve it automatically).
- Distribution is sideload-only (no App Store target).
- No test suite, no linter configured.
- App icon / top shelf image assets are auto-generated placeholders (solid
  color + "B") — replace before distributing to anyone else.

## Architecture

Mirrors CloudNow's five functional areas:

- **Auth**: `AuthManager.swift` (`@Observable @MainActor` state holder) +
  `BoosteroidAuthAPI.swift` (cookie-session completion — real login flow
  confirmed, token/refresh mechanics still TODO) + `AuthCore.swift` (Keychain,
  PKCE, token/user models — protocol-agnostic) + `UI/WebLoginCaptureView.swift`
  (WKWebView login; now auto-detects success via navigation to `/dashboard`).
- **Session**: `SessionState.swift` (data models — `SessionInfo.nodeBaseUrl` is
  the key confirmed addition) + `BoosteroidClient.swift` (catalog + session
  lifecycle against confirmed URLs; most response decoding still TODO).
- **Streaming**: `StreamController.swift` (WebRTC peer connection lifecycle —
  now implements the CONFIRMED client-is-offerer flow: create offer → POST to
  `/webrtc/api/call` → get answer → trickle ICE both ways) +
  `SignalingClient.swift` (REST-based webrtc-streamer client, replacing the
  earlier WebSocket-based guess entirely) + `SDPMunger.swift` (generic SDP
  codec/bandwidth rewriting, reused near-verbatim from CloudNow) +
  `InputSender.swift` (reads keyboard/mouse/controller state fine; wire
  encoding still a no-op stub — input transport unconfirmed).
- **Video**: `VideoSurfaceView.swift` — WebRTC frame rendering via
  `AVSampleBufferDisplayLayer`, plus HID→Windows-VK/scancode keyboard mapping.
  Reused near-verbatim from CloudNow; protocol-agnostic as long as Boosteroid's
  game hosts are Windows-based (the eFootball session strongly suggests so).
- **UI (SwiftUI)**: `BoosteroidATVApp.swift` (root), `MainTabView.swift`,
  `HomeView.swift` (minimal — catalog response shape still TODO),
  `LoginView.swift`, `SettingsView.swift`, `StreamView.swift`.

## Key Patterns

Same as CloudNow: `@Observable + @MainActor` throughout, no Combine/Redux.
