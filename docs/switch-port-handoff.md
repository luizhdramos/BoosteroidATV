# Boosteroid Protocol & Reverse-Engineering Handoff

**Written for:** whoever is porting Boosteroid to Nintendo Switch.
**Source project:** BoosteroidATV — an unofficial, reverse-engineered Boosteroid
cloud-gaming client for tvOS (Swift/SwiftUI), built the same way this doc's
findings were: no official SDK or docs exist, everything below was learned by
capturing real traffic from the official apps and the web client.

Nothing here is officially documented by Boosteroid. Every claim below is
either **CONFIRMED** (verified against real captured traffic or a real working
session) or explicitly flagged **TODO(protocol)** / **UNCONFIRMED** (a
reasonable guess, or something read from source but never seen on the wire).
Treat the CONFIRMED items as safe to implement directly; treat the rest as a
starting point that still needs its own verification pass.

---

## 1. TL;DR — the load-bearing facts

- Everything lives under **`cloud.boosteroid.com`**. There is no separate API
  host.
- Login is a plain REST call: `POST /api/v1/auth/login` with
  `{client_id, client_secret, email, password}`. **It requires a specific
  fixed header, `x-nonce-17: 18211`, or it's silently rejected** — this cost
  the most debugging time of anything in this doc (see §3).
- The REST API (catalog, session lifecycle, user info) is **cookie-session**
  authenticated. The login response's `Set-Cookie` headers are what matter;
  the JSON body's `access_token`/`refresh_token` are used for the WebSocket
  and as a belt-and-suspenders `Authorization` header, but cookies alone are
  sufficient for the REST calls.
- Getting a game running is a 3-stage handoff: **queue** (REST enqueue +
  realtime WebSocket for position) → **claim** (REST, exactly once, triggered
  by a WebSocket push) → **stream** (a per-session control WebSocket that
  gates a REST-based WebRTC signaling exchange).
- **The single most important fork-in-the-road decision for a Switch port**:
  the control WebSocket's `clientType` query parameter determines the video
  transport server-side. `clientType=web` → the server does WebRTC signaling.
  `clientType=native` → the server does **raw UDP** instead and never sends
  the WebRTC-start signal at all. Boosteroid's own protocol already
  anticipates non-browser clients as raw-UDP consumers — this may well be the
  righter path for a Switch homebrew client than dragging in a WebRTC stack.
  See §5.

---

## 2. Architecture at a glance

```
Login (REST, cookie-session)
   │
   ▼
Catalog / library (REST, cookie-session)
   │
   ▼
Enqueue (REST) ──► Realtime WebSocket (wss://cloud.boosteroid.com/ws?uid=&token=)
   │                    │  queue position pushes, then a "machine ready" push
   │                    ▼
   │              Claim (REST, POST session/start, exactly once)
   ▼                    │
session/details (REST) ◄┘   → returns the per-node gateway host + a signed queryString
   │
   ▼
Control WebSocket (wss://{gatewayHost}/?{queryString}&...&clientType=web|native)
   │  - claims the session for THIS device (kicks any other active client)
   │  - carries ALL input (keyboard/mouse/gamepad) as JSON frames
   │  - pushes "start WebRTC now" (clientType=web) or udpforward info (clientType=native)
   ▼
WebRTC signaling (REST, against the SAME per-node gateway host)
   getIceServers → getParams → call (SDP exchange) → addIceCandidate / getIceCandidate (poll)
   ▼
Video/audio media (WebRTC, H.264 confirmed; H.265/AV1 unconfirmed)
```

---

## 3. Authentication

### 3.1 Direct email/password login (CONFIRMED end-to-end, working)

This is what Boosteroid's own Android TV app's "Sign in Manually" button
does — no CAPTCHA, no OAuth redirect, no browser needed. This is almost
certainly the right login mechanism for a Switch client too (a browser-based
OAuth/Turnstile flow is not realistic on Switch either).

```
POST https://cloud.boosteroid.com/api/v1/auth/login
Content-Type: application/json; charset=UTF-8
Accept: application/json
User-Agent: BoosteroidAndroidTVClient v.2.5.10.tv; Android 14; sdk_gphone64_arm64
device-name: emu64a sdk_gphone64_arm64 34
device-uniq-id:
accept-language: en-US
device-info: {"brand":"google","chip":" ","device":"emu64a","hardware":"ranchu","manufacturer":"Google","model":"sdk_gphone64_arm64","name":"UE1A.230829.050","product":"sdk_gphone64_arm64"}
Cookie: boosteroid_entrypoint_source=1;boosteroid_entrypoint_page=1
x-nonce-17: 18211

{"client_id":6,"client_secret":"CDYb8AnfFEeU3p4Rd1A3oGonxMJMe3TdWJwDWSsy","email":"you@example.com","password":"your-password"}
```

**Critical, hard-won finding: `x-nonce-17: 18211`.** Sounds like a per-request
nonce/signature, but it isn't — it was captured **identical** across two
separate real logins, made from cold app starts, minutes apart. That rules
out a counter or a timestamp; it's a fixed constant baked into this specific
app build (`v.2.5.10.tv`). Without it, the request gets a generic-sounding
rejection (`"something wrong with your data"`, HTTP-level, no real error
code). **If you're targeting a different Boosteroid app version, re-capture
this value — don't assume `18211` is universal.** See §7 for how to capture
it yourself.

Also required, empirically: a **non-browser `User-Agent`**. The exact same
request with a desktop-browser UA (used elsewhere for the cookie-session
compatibility) gets refused — the backend most likely branches on UA to
decide whether to demand a Cloudflare Turnstile token, and refuses outright
if it can't tell you're a real native client presenting neither a browser UA
nor a Turnstile pass. `device-name`/`device-info` are almost certainly just
telemetry (not validated against a real device), but were left in verbatim
since they came from a known-working request — cheap insurance.

**Response** on success (HTTP 200):

```json
{
  "data": {
    "user": { "id": 9573264, "name": "...", "email": "...", "avatar": "https://...", "...": "..." },
    "access_token": "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9...",
    "refresh_token": "def50200...",
    "expires_in": "2026-08-26 20:00:41"
  }
}
```

- `expires_in` is **misleadingly named — it's an absolute timestamp**
  (`yyyy-MM-dd HH:mm:ss`, UTC), not a duration in seconds.
- The response ALSO carries `Set-Cookie` for `access_token`, `refresh_token`,
  `boosteroid_auth`, `boosteroid_session` — **these cookies are what every
  other REST call actually needs** (see §3.3). `boosteroid_session` has a
  short (24h) `Max-Age` but appears to be reissued/rotated on every
  subsequent authenticated request (Laravel-style sliding session) — as long
  as you keep making requests, it likely never truly expires; this wasn't
  stress-tested past a single session's lifetime.
- No working **refresh** mechanism is known. When the session goes stale,
  the only confirmed path is calling `/api/v1/auth/login` again.

Error shape (HTTP 4xx), when the server can parse the request but the
credentials/lookup fail:

```json
{"error":{"message":"We could not find those credentials."},"error_code":142299,"error_message":"We could not find those credentials.","error_number":20000023}
```

A *different* error/status shows up for missing/invalid required headers
(e.g. wrong `x-nonce-17` or a browser `User-Agent`) — HTTP-level rejection,
generic body, no useful `error_code`. Don't conflate the two failure modes:
one is "your headers are wrong," the other is "your credentials are wrong."

### 3.2 QR-code login (partially reverse-engineered, NOT fully needed once §3.1 worked)

Boosteroid's TV apps also offer a QR-code pairing flow (scan with phone →
auto-login on TV). Two endpoints were found; a third (code generation) was
not:

- **TV side, polls repeatedly while waiting**:
  ```
  POST /api/v1/auth/login/qr-code/sync
  Content-Type: application/json; charset=UTF-8
  (same headers as §3.1, including x-nonce-17)

  {"auth-code":"<uuid>","clientId":6}
  ```
  Returns `401` `{"error":{"message":"Unauthenticated."},"error_code":940199,...}`
  while nobody has confirmed the code yet. The `auth-code` UUID **changes
  about every ~90 seconds** (matches the QR's visible "expired, tap refresh"
  behavior) — so it's client-generated and refreshed on a timer, not
  server-issued.
- **Phone/web side, confirms a scanned code** (found via static analysis of
  the web client's bundle, not live-captured):
  ```
  POST /api/v1/auth/login/qr-code/validate
  (must be called by an ALREADY-AUTHENTICATED session — this is "I am logged
  in on my phone/browser and I just scanned this TV's code")

  {"auth-code":"<the same uuid the TV displayed>"}
  ```
- **UNCONFIRMED / never found**: the endpoint that actually *generates* the
  QR code's underlying value or a WebSocket that pushes the pairing
  confirmation to the TV. Since direct login (§3.1) fully replaces the need
  for this, it wasn't pursued further. If a Switch client wants QR pairing
  specifically (e.g. because typing a password with a joystick is painful),
  this is the remaining gap — start by watching what the TV app's QR screen
  does differently from its "Sign in Manually" screen using the method in
  §7.

### 3.3 REST API auth model (cookie-session, not bearer)

CONFIRMED by direct testing: `GET /api/v1/user` and all other `/api/v1/*`
and `/api/v2/*` calls work with **cookies alone** — no `Authorization`
header needed. What DOES matter for a from-scratch (non-browser) HTTP
client:

- Send the `Cookie` header built from the cookies captured at login (just
  `name=value; name2=value2`, semicolon-joined).
- Send `Origin: https://cloud.boosteroid.com` and
  `Referer: https://cloud.boosteroid.com/dashboard` — Laravel/Sanctum-style
  backends commonly gate cookie-session auth on these matching, and requests
  without them were seen to fail.
- Send `Accept: application/json`.

The realtime WebSocket (§4) and the streaming control WebSocket (§5) are
different: they authenticate via the **raw JWT** (`access_token` minus the
`"Bearer "` prefix) as a query parameter, not cookies.

---

## 4. Session / queue lifecycle

1. **`POST /api/v2/streaming/session/enqueue`** — body `{"appId": <int>}` →
   `204`, no response body. Puts the account in a queue for a free VM. Only
   ONE session per account at a time; enqueueing a different game orphans
   whatever the account was previously holding (confirmed intentional — the
   web client does the same "switch device / switch game" thing).

2. **`GET /api/v1/streaming/user/last-session`** → 
   `{"data":{"sessionId":"<uuid>","appId":<int>,"status":"EN"|"LI"}}`.
   `"EN"` = queued/enqueued, `"LI"` = live/active. **This record can be
   STALE** — it's been observed returning an old, already-ended session's
   data. Never trust it in isolation; always cross-check against
   `session/details` (step 5) actually returning a gateway before treating a
   session as real.

3. **Realtime WebSocket** — `wss://cloud.boosteroid.com/ws?uid=<numeric user
   id>&token=<raw JWT, no "Bearer " prefix>`. Every message is JSON
   `{"type":..., "action":..., "value":...}`. Confirmed by live capture:
   - `{"type":"queues","action":"state","value":{"appId":N,"position":N,"eta":secondsN}}`
     — pushed roughly once a second while queued. **Per-app, and covers every
     queue the account is in** (including stale leftovers from other games)
     — match on `appId`, don't assume the first push is about your game.
   - `{"type":"queues","action":"start","value":{"appId":N,"token":"<uuid>"}}`
     — "a machine is reserved for you." **This exact moment is the ONLY
     correct time to claim** (step 4) — polling the claim endpoint on a
     timer instead gets you rate-limited (a 6-second retry loop earned a real
     HTTP 429 with an 8-minute lockout). The `token` field here is a
     **different UUID than the session id** and is REQUIRED for the claim
     call.
   - `{"type":"pong"}` — heartbeat reply.
   - Not every game produces a `queues/state` push at all (observed with one
     specific game) — a missing position display isn't necessarily broken.

4. **Claim, exactly once, in response to the `queues/start` push**:
   ```
   POST /api/v2/streaming/session/start
   {"appId": <int>, "sessionToken": "<the token from queues/start>"}
   ```
   There is also a `v1` endpoint with the same path/appId-only body that
   looks superficially identical — it is a DIFFERENT feature ("start without
   queueing") and returns `400 "Direct session start not allowed."`. The
   `v2` + `sessionToken` combination is mandatory; omitting the token gives
   `422 "The session token field is required."`, and passing the session
   UUID instead of the real token gives `400`.

5. **`POST /api/v1/streaming/session/details?sessionId=<uuid>`** (POST, not
   GET — GET returns `405`). Success:
   ```json
   {"data":{"gw":"https://sp7.cloud.boosteroid.com:443","queryString":"<jwt>"}}
   ```
   `gw` is the per-session gateway host — everything in §5 happens against
   THIS host, not `cloud.boosteroid.com`. `queryString` is a signed JWT
   that's appended verbatim to the control WebSocket URL. While still queued
   (or for an expired/idle session) this returns `406` with
   `{"data":{"code":"timeout",...}}` instead — treat that as "keep waiting,"
   not a hard error. Can also return a transient empty `200` body right
   after another client claims the same session — retry a couple of times
   before giving up.
   
   There's also `GET /v1/streaming/gateways` (list of ~16 candidate gateway
   hosts with a `priority` flag) — **do not use this to pick a host**; the
   account has multiple priority gateways and guessing one wrong breaks the
   control socket. The only correct gateway is the one `session/details`
   itself hands back.

6. **Ending a session**: no REST teardown call was ever found. Almost
   certainly goes out over one of the WebSockets above instead. Unconfirmed
   — worth a dedicated capture pass if a Switch client needs a clean
   "stop streaming" button rather than just disconnecting.

**Rate limiting is real and easy to trip.** A naive "poll everything every
few seconds" loop earned escalating lockouts (8min → 15min → 32min) on a
real account. Poll `last-session`/`session/details` slowly (tens of seconds)
while genuinely queued — the realtime WebSocket is the actual signal for
progress; REST polling here is only a fallback safety net for when the
WebSocket itself drops.

---

## 5. Streaming control WebSocket — READ THIS BEFORE CHOOSING A VIDEO TRANSPORT

```
wss://{gatewayHost}/?{queryString}
    &x={width}&y={height}
    &lang={lang}&refreshRate={fps}
    &rtcEngine=webrtc
    &clientType={web|native|controller}
    &devType={desktop|mobile|tv|avtomotive|tablet}
    &os={win|lin|mac|a|atv|webos|tizen|titan|vidaa|fireos}
    &rtcAudio=pcm
```

- `{gatewayHost}` and `{queryString}` are exactly what `session/details`
  (§4.5) returned.
- **Opening this socket CLAIMS the session for this device** — confirmed
  live: opening a second control socket against a session already streaming
  in a browser instantly kicked that browser to a "switched to another
  device" screen. Don't open it before you're actually ready to stream.
- **`clientType` determines the video transport, server-side — CONFIRMED
  live, and this is the single most consequential protocol fact in this
  document for a new port:**
  - `clientType=web` → the server sends a `{"type":"settings","action":"webrtc"}`
    push on this socket, telling the client to start WebRTC signaling
    (§6). This is what BoosteroidATV (and presumably the real web client)
    uses.
  - `clientType=native` → the server sends `{"type":"settings","action":"udpforward"}`
    instead (carrying `ip`/`videoport`/`audioport`) and **never** sends the
    WebRTC-start signal. It expects you to receive a raw UDP media stream
    keyed by a `stream/key` value pushed separately, not negotiate WebRTC at
    all.
  - Boosteroid's own client enumerates `native`/`tv`/`atv` as recognized
    `devType`/OS values, so a non-browser TV/console client is clearly
    anticipated by the protocol — just as a **raw-UDP consumer**, not a
    WebRTC one.
  
  **For a Switch port: seriously consider the `clientType=native` / raw-UDP
  path instead of WebRTC.** WebRTC on Switch means either porting a full
  WebRTC stack (heavy, and this project only managed it on Apple platforms
  via a prebuilt `livekit/webrtc-xcframework`) or building your own thin
  RTP-ish UDP receiver against a protocol Boosteroid already speaks
  natively. Nobody has implemented or captured the raw-UDP path in this
  project — it was deliberately not pursued because BoosteroidATV needed
  WebRTC (livekit) either way for other reasons — but the `udpforward`
  message's `ip`/`videoport`/`audioport` fields are a concrete, confirmed
  starting point if you want to go that route instead.

- The socket carries **all input** (keyboard/mouse/gamepad) as plain JSON
  text frames, entirely separate from whichever media transport you end up
  using. See §6.3 for the exact per-type shapes — these apply regardless of
  which `clientType` you pick.

- **The handshake sequence that makes video actually start** (confirmed the
  hard way — getting this order wrong left a fully-connected WebRTC peer
  receiving zero bytes):
  1. Open the control socket, wait for `settings/webrtc` (or, if attaching
     to a session another device already initialized, a `stream/*` config
     burst is an equally valid trigger).
  2. Do WebRTC signaling (§6).
  3. Once the peer connection is up, the server sends
     `{"type":"stream","action":"getstatus"}` on the CONTROL socket (not
     WebRTC) and **waits for a reply** before sending any video. Reply with:
     ```json
     {"type":"keyboard","action":"language","code":1033}
     {"type":"stream","action":"status","value":"ok","params":{"type":"web","ver":"v_7.4.17","gpu":"<any string>","proto":1,"framerate_max":60,"cursor_zip":false,"filler":false,"beta":0,"rtcEngine":"webrtc","rtcAudio":"pcm"}}
     {"type":"stream","action":"refreshRate","value":60}
     ```
     (`code:1033` = the Windows LCID for en-US; adjust if you support other
     languages the same way.)
  4. Bandwidth is a separate explicit message, not an SDP hint:
     `{"type":"stream","action":"bandwidth","value":<bits-per-second>}`.

- The remote desktop's cursor is **not composited into the video** — the
  official clients draw it themselves from a separate `cursor`-ish push on
  this socket. The exact message shape was never fully pinned down (parsed
  leniently in this project); if you need a visible cursor, budget time to
  capture and confirm this specific message.

---

## 6. WebRTC signaling (only relevant if you pick `clientType=web`)

REST-based, against the per-session **gateway host** from §4.5 (NOT
`cloud.boosteroid.com`). Matches the shape of the open-source
[`webrtc-streamer`](https://github.com/mpromonet/webrtc-streamer) project
closely enough that this is almost certainly what Boosteroid's server runs.
Send the same `Cookie`/`Origin`/`Referer` headers as the main REST API (§3.3)
— calls without them were suspected (not conclusively proven) to be the
cause of an empty/failed response early in a session's life.

```
GET  {gw}/webrtc/api/getIceServers?sessionId={id}
  → {"iceServers":[{"credential":"...","urls":["turn:HOST:3478?transport=udp"],"username":"<unixSeconds>:boosteroid"}],"iceTransportPolicy":"all"}
  (CONFIRMED verbatim from a real session)

GET  {gw}/webrtc/api/getParams?sessionId={id}
  → {"codec":"H264","version":1}
  (CONFIRMED verbatim; whether H.265/AV1 are ever offered is UNCONFIRMED)

POST {gw}/webrtc/api/call?peerid={rand}&sessionId={id}
  body: {"sdp":"<local offer>","type":"offer"}     — UNCONFIRMED body (OSS convention, not captured byte-for-byte)
  → {"sdp":"<remote answer>", ...}                  — UNCONFIRMED response shape, same caveat

POST {gw}/webrtc/api/addIceCandidate?peerid={rand}&sessionId={id}
  body: {"candidate":"...","sdpMid":"...","sdpMLineIndex":N}   — UNCONFIRMED body shape

GET  {gw}/webrtc/api/getIceCandidate?peerid={rand}&sessionId={id}
  → array of candidate objects — poll repeatedly (1s worked; the real interval is UNCONFIRMED)
```

`peerid` is a plain JS `Math.random()` float rendered as a string (e.g.
`"0.9150882553499954"`) — not a UUID, no particular format enforced as far
as observed.

**Important operational note**: the assigned VM can be "LI" (live, per
`session/details`) before its own streaming service has actually finished
booting. `getIceServers`/`getParams` can return a `502 {"error":"Bad
Gateway","message":"Target service unavailable"}` — or valid JSON missing
its usual keys, e.g. `{}` — for up to ~90 seconds after the session goes
live. This is normal startup lag, not a failure; retry rather than erroring
out immediately.

SDP handling notes (platform-agnostic, not Boosteroid-specific, but
confirmed necessary in practice): munge the **answer** you receive, not the
offer you send — munging the offer left orphaned SSRC lines that caused
problems. Filter to your preferred codec by pruning `m=video` payload types
and their associated `rtcp-fb`/`fmtp` lines; if you support H.265, prefer
`profile-id=1` (Main profile) payload types over other H.265 profiles found
in the same answer.

---

## 7. Reverse-engineering methodology — how all of the above was actually found

If the Switch port needs to confirm or extend anything above (the QR-code
generation endpoint, the raw-UDP `udpforward` message shape, session
teardown, a newer app version's `x-nonce-17` value, ...), this is the
concrete, working pipeline that produced everything CONFIRMED in this doc.
It's checked into BoosteroidATV at `tools/android-tv-capture/` — copy it
wholesale, it has no tvOS/Apple dependency, it's pure macOS shell + Python +
Frida.

**The short version**: boot an Android TV emulator, install Boosteroid's own
Android TV app on it from the Play Store, route its traffic through
mitmproxy, and use Frida to disable the app's TLS certificate pinning so
mitmproxy can actually read the (otherwise encrypted-and-pinned) traffic.

**The gotchas that actually cost time, in order encountered** (so you don't
repeat them):

1. **Google Sign-In actively detects and refuses to work through an
   intercepting proxy.** Boot the emulator with NO proxy, sign into the Play
   Store and install the target app while still proxy-free, THEN restart the
   same emulator (its disk state survives) with the proxy on.
2. **A soft, in-Android "system proxy" setting
   (`adb shell settings put global http_proxy ...`) is not enough** — many
   apps' network stacks simply ignore it. Use the emulator's own
   `-http-proxy http://127.0.0.1:8080` boot flag instead, which transparently
   redirects ALL traffic at the network layer regardless of what the app
   does.
3. **Certificate pinning will silently swallow everything** even with the
   proxy genuinely working (confirmed via other apps' traffic/TLS failures
   showing up normally in the same capture) — you'll see zero requests,
   zero TLS failures, nothing, for the pinned app specifically. The fix is
   Frida:
   - Pull the target app's APK(s) off the signed-in emulator
     (`adb shell pm path <package>` — note it may return SEVERAL files if
     Play Store installed it as a base + split APKs; pull and
     `adb install-multiple` all of them together, not just the base).
   - Boot a SEPARATE, **rootable** `google_apis` (non-Play-Store) system
     image — Play Store images deliberately refuse `adb root`. Sideloading
     via `adb install-multiple` works fine on a non-TV-shaped image; Play
     Store's TV-only visibility filtering doesn't apply to direct installs.
   - Push and run a matching `frida-server` binary on that rooted device
     (must match your host's `frida-tools` version AND the device's CPU
     ABI exactly, or it won't attach).
   - **Spawn** the app under Frida (`frida -U -f <package> -l script.js`),
     don't try to *attach* to it — attaching requires the app to already be
     running, which a fresh install never is.
   - Use a Java-level SSL-pinning bypass script hooking `SSLContext.init`,
     OkHttp's `CertificatePinner.check` (both overloads), Conscrypt's
     `TrustManagerImpl.verifyChain`, and `WebViewClient.onReceivedSslError`
     — wrap each hook in its own try/catch, since a public one-size-fits-all
     script (`akabe1/frida-multiple-unpinning` from Frida CodeShare) was
     tried first and crashed outright on a newer Frida version, taking down
     every hook with it. A small in-house script with per-hook try/catch
     (checked into this repo as `tools/android-tv-capture/unpin.js`) is more
     robust than depending on an unmaintained public one.
   - **If a Java-level bypass doesn't produce plaintext traffic for a
     specific host** (you were seeing `TLS HANDSHAKE FAILED` entries for it
     before, and now see nothing at all, success or failure): that means the
     app validates certificates in **native code** (a statically-linked
     BoringSSL/OpenSSL, common in game-streaming/anti-tamper-conscious
     apps), which Java-level Frida hooks can't reach. This project's target
     app (`cloud.boosteroid.com`) was NOT found to do this — the Java-level
     bypass worked — but if a Switch-relevant capture hits this wall, the
     next step is hooking native TLS verification functions directly
     (`SSL_CTX_set_custom_verify`/`SSL_get_verify_result` in `libssl.so`),
     which is a meaningfully bigger undertaking.
4. **mitmproxy addon**: log EVERY contacted host unconditionally (not just
   ones matching an expected keyword) to a plain text file, plus TLS
   handshake failures and flow-level errors, in addition to the filtered
   "interesting" capture. This is what actually revealed the `x-nonce-17`
   fixed value — repeated capture, diffed by eye against an earlier one.
5. **A shell scripting trap worth knowing about regardless of this specific
   project**: `yes | some-interactive-command` under `set -e` +
   `set -o pipefail` can silently kill your whole script. `yes` gets
   SIGPIPE'd (nonzero exit) the instant the downstream command stops
   reading stdin; under `pipefail` that registers as the whole pipeline
   failing. Append `|| true` if the downstream command's own exit status is
   checked separately anyway.

`tools/android-tv-capture/README.md` has the fuller step-by-step and a
troubleshooting section for each of the above. `tools/android-tv-capture/setup.sh`
and `setup-unpin.sh` are runnable scripts, not just notes — copy them and
adjust the target package name / any Switch-specific paths as needed.

---

## 8. Known unknowns (things worth re-confirming, not facts to build on blind)

- No refresh-token mechanism is confirmed to exist for the direct-login
  session — re-login is the only known path once it goes stale.
- Session teardown ("stop streaming" as a clean REST call) was never found —
  likely goes out over one of the WebSockets instead.
- The QR-code *generation* endpoint (as opposed to the TV-side polling and
  phone-side confirmation endpoints, both of which ARE confirmed) was never
  found or captured.
- WebRTC `call`/`addIceCandidate` request and response bodies are assumed
  from the upstream `webrtc-streamer` OSS project's convention, not
  confirmed byte-for-byte against real captured traffic.
- The `clientType=native` raw-UDP path's full message/stream protocol
  (beyond the `udpforward` push's `ip`/`videoport`/`audioport` fields) was
  never explored — see §5's note on why this may matter a lot more for a
  Switch port than it did for this Apple-platform one.
- The control socket's cursor-position push shape was never fully pinned
  down (parsed leniently, several possible field names tried).
- Whether H.265 or AV1 are ever actually offered by Boosteroid's server is
  unconfirmed — only H.264 was seen in the one real session this was
  captured from.
- `x-nonce-17`'s value is confirmed fixed *for this specific app build*
  (`v.2.5.10.tv`) — it is NOT confirmed to be version-independent. Re-capture
  it against whatever app version you're targeting.

---

## 9. Reference implementation map (Swift/tvOS — algorithm/behavior reference only)

Not portable code (different language and platform), but each file below is
where the corresponding protocol knowledge above was actually implemented,
with much more detailed "CONFIRMED on <date> because <specific evidence>"
commentary than this summary has room for. Worth reading directly if
something above is ambiguous.

| File | Covers |
|---|---|
| `BoosteroidATV/Auth/AuthCore.swift` | Constants (host, client_id/secret), session/token models |
| `BoosteroidATV/Auth/BoosteroidAuthAPI.swift` | The login call itself — full header/body detail, all the "first attempt failed because..." history |
| `BoosteroidATV/Session/BoosteroidClient.swift` | Catalog, queue/session lifecycle, rate-limit handling |
| `BoosteroidATV/Session/BoosteroidRealtimeClient.swift` | The `wss://.../ws` queue-position/ready socket |
| `BoosteroidATV/Streaming/BoosteroidControlChannel.swift` | The per-session control socket — URL construction, ALL input wire shapes, the webrtc-vs-udpforward fork, the getstatus handshake |
| `BoosteroidATV/Streaming/SignalingClient.swift` | The WebRTC REST signaling calls |
| `BoosteroidATV/Streaming/SDPMunger.swift` | Codec filtering / bandwidth injection (generic, not Boosteroid-specific) |
| `BoosteroidATV/Streaming/InputSender.swift` | How the wire shapes in `BoosteroidControlChannel.swift` get built from real keyboard/mouse/controller input |
| `tools/android-tv-capture/` | The whole capture pipeline from §7 — runnable, not just described |

Explicitly **NOT relevant** to a Switch port: anything about tvOS's missing
WebKit/browser APIs, Keychain usage, SwiftUI view code, or `AVSampleBufferDisplayLayer`
— all Apple-platform-specific plumbing around the protocol, not the protocol
itself.
