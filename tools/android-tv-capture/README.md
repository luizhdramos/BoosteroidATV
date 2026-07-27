# Capturing the Boosteroid Android TV QR-login request

Goal: find the real HTTP request Boosteroid's Android TV app makes to
generate its QR-code login (and the one it polls to check whether the phone
confirmed it), so the same thing can be implemented in the Apple TV app.

## Run it

```
cd android-tv-capture
bash setup.sh
```

The script does almost everything itself — installs Homebrew packages,
downloads an Android TV emulator image with Play Store, boots it, starts
mitmproxy, and wires the emulator to send its traffic through it.

It pauses at exactly three points, because these genuinely require a human
(Android/Google intentionally don't allow scripting past them):

1. **Trusting the mitmproxy certificate** — one confirmation tap in
   Settings. Without this, HTTPS traffic is unreadable ciphertext.
2. **Signing into your Google account** in the Play Store, inside the
   emulator. Type it directly there — this is never something an AI
   assistant should see or handle.
3. **Installing "Boosteroid Cloud Gaming TV"** and navigating to its QR
   login screen.

Everything else — creating the AVD, booting it, launching mitmproxy,
pushing the certificate file, opening the Play Store, launching the app —
is automated.

## What you get

`boosteroid-capture.jsonl` in this same folder: one JSON object per line,
only for requests whose host contains "boosteroid" (everything else —
Google Play, telemetry — is filtered out). Each line has the method, full
URL, request/response headers and bodies.

If it's empty after reaching the QR screen, leave mitmweb running (its UI
is at http://127.0.0.1:8081 — refresh and look for anything to a boosteroid
host) and back out and re-enter the login screen once or twice; some apps
only make the call once per cold start.

## Handing it back

Once you have `boosteroid-capture.jsonl`, either:

- Copy it into the BoosteroidATV repo folder (or paste its contents in
  chat) — Claude can read it directly and pull out the endpoint, request
  shape, and polling mechanism, the same way the mouse/keyboard protocol
  was reverse-engineered from the web client earlier in this project.

## If something goes wrong

- **No Android TV + Play Store image was found for your Mac's chip**: the
  script automatically falls back to a phone-shaped Play Store image. The
  TV app may not show up in Play Store search on a phone profile — if so,
  get the APK off a real device that already has it installed
  (`adb shell pm path com.boosteroidtv.streaming` then `adb pull <path>`)
  and `adb install` it instead of using Play Store.
- **mitmweb shows nothing at all, even for other apps**: the emulator's
  proxy setting probably didn't take — rerun
  `adb shell settings put global http_proxy 10.0.2.2:8080` manually.
- **Boosteroid's app immediately errors out / won't load anything**: it may
  be using certificate pinning, which would block this approach entirely
  for THAT request. Note which specific screen fails and share that — it
  changes the plan (would need a rooted/patched approach instead).
