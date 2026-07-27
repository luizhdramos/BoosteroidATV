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

**Important:** the emulator boots with NO proxy active, and stays that way
through Google sign-in. Google Sign-In actively detects and refuses to work
through an intercepting proxy (a real anti-abuse measure, not a bug) — if
the proxy were on from boot, logging into Google would just fail outright.
The script only turns the proxy on AFTER Play Store sign-in/install is
done, right before launching Boosteroid — so only Boosteroid's own traffic
ever goes through mitmproxy. Don't open Boosteroid before that point, or its
first-run requests won't be captured.

It pauses at exactly three points, because these genuinely require a human
(Android/Google intentionally don't allow scripting past them):

1. **Trusting the mitmproxy certificate** — one confirmation tap in
   Settings. Without this, HTTPS traffic is unreadable ciphertext.
2. **Signing into your Google account** in the Play Store, inside the
   emulator. Type it directly there — this is never something an AI
   assistant should see or handle. The proxy is off for this step.
3. **Installing "Boosteroid Cloud Gaming TV"** — also proxy-off. The script
   turns the proxy on right after this pause, then launches the app itself.

Everything else — creating the AVD, booting it, launching mitmproxy,
pushing the certificate file, opening the Play Store, toggling the proxy
at the right moment, launching the app — is automated.

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

- **Can't sign into Google / Play Store rejects the login**: two known
  causes, try them in order.
  1. The proxy being on too early — Google blocks sign-in through any
     intercepting proxy on purpose. Check `adb shell settings get global
     http_proxy`; if it prints anything other than `null`, turn it off with
     `adb shell settings put global http_proxy :0`, then try signing in
     again. (setup.sh no longer does this to itself — the proxy isn't
     enabled until after Play Store sign-in/install — but a leftover AVD
     from before that fix could still have it set.)
  2. The system image itself: brand-new API levels sometimes fail Google's
     Play Integrity/attestation check on emulated hardware, which shows up
     as sign-in silently failing with no useful error. Force an older,
     better-tested image instead of whatever setup.sh auto-picked:
     ```
     grep atv_playstore /tmp/boosteroid-sdk-list.txt   # see what's on offer
     IMAGE_OVERRIDE='system-images;android-30;google_atv_playstore;x86_64' bash setup.sh
     ```
     (swap `x86_64` for `arm64-v8a` if that ABI is listed and you're on
     Apple Silicon). setup.sh now names the AVD after the image it's built
     from, so switching images always gets a clean AVD instead of reusing
     whatever state — possibly corrupted by a earlier failed sign-in — the
     old one had on disk.
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
