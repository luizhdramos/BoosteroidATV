#!/usr/bin/env bash
#
# setup.sh — spins up an Android TV emulator (with Play Store) and a
# mitmproxy capture, with as little manual interaction as possible, so we can
# find the real HTTP request Boosteroid's Android TV app makes to generate
# its QR-code login pairing (the same endpoint the Apple TV app needs to hit).
#
# What this script automates for you:
#   - Installs Homebrew packages it needs (Android command-line tools, mitmproxy)
#   - Downloads and accepts licenses for an Android TV system image with Play Store
#   - Creates and boots the AVD
#   - Points the emulator's network at a mitmproxy instance and starts it
#   - Pushes the mitmproxy CA certificate onto the device and opens the
#     "install certificate" screen directly
#   - Launches the Play Store on the device
#
# What it CANNOT automate (Android/Google intentionally require a human here):
#   - Signing into your Google account inside the emulator (never type your
#     Google password anywhere I can see it — this script just gets you to
#     the sign-in screen)
#   - The one confirmation tap Android requires to trust a new CA certificate
#   - Installing "Boosteroid Cloud Gaming TV" from the Play Store UI itself
#   - Navigating the Boosteroid app to its QR-code login screen
#
# The script pauses with clear instructions at each of those points — just
# press Enter when you're done with that step, and it continues.
#
# Run it with:  bash setup.sh
#
set -euo pipefail

AVD_NAME="BoosteroidTV"
MITM_PORT=8080
MITM_WEB_PORT=8081
CAPTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_FILE="$CAPTURE_DIR/boosteroid-capture.jsonl"
CERT_PEM="$CAPTURE_DIR/mitmproxy-ca.pem"
ADB=""
SDKMANAGER=""
AVDMANAGER=""
EMULATOR_BIN=""

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
pause() { printf '\n\033[1;33m--> %s\033[0m\n' "$1"; read -r -p "    Press Enter when done... " _; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1"; exit 1; }

# ---------------------------------------------------------------------------
log "Checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew isn't installed. Install it from https://brew.sh first, then re-run this script."
fi

# ---------------------------------------------------------------------------
log "Installing mitmproxy (if needed)"
if ! command -v mitmweb >/dev/null 2>&1; then
  brew install mitmproxy
fi

# ---------------------------------------------------------------------------
log "Installing Android command-line tools (if needed)"
if ! command -v sdkmanager >/dev/null 2>&1 && [ ! -d "$HOME/Library/Android/sdk" ]; then
  brew install --cask android-commandlinetools
fi

# Locate the SDK regardless of how it got installed (Homebrew cask, Android
# Studio, or an existing manual install).
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
if [ ! -d "$ANDROID_SDK_ROOT" ]; then
  # Homebrew's cask installs cmdline-tools under its own prefix; fall back there.
  BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  if [ -d "$BREW_PREFIX/share/android-commandlinetools" ]; then
    ANDROID_SDK_ROOT="$BREW_PREFIX/share/android-commandlinetools"
  fi
fi
[ -d "$ANDROID_SDK_ROOT" ] || die "Couldn't find the Android SDK. Set \$ANDROID_SDK_ROOT to its path and re-run."
export ANDROID_SDK_ROOT
export ANDROID_HOME="$ANDROID_SDK_ROOT"

SDKMANAGER="$(find "$ANDROID_SDK_ROOT" -name sdkmanager -type f 2>/dev/null | head -n1)"
[ -n "$SDKMANAGER" ] || die "Couldn't find sdkmanager under $ANDROID_SDK_ROOT."
AVDMANAGER="$(find "$ANDROID_SDK_ROOT" -name avdmanager -type f 2>/dev/null | head -n1)"
[ -n "$AVDMANAGER" ] || die "Couldn't find avdmanager under $ANDROID_SDK_ROOT."

log "Accepting SDK licenses (non-interactive)"
yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "Finding the best Android TV + Play Store system image"
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
  PREFERRED_ABI="arm64-v8a"
else
  PREFERRED_ABI="x86_64"
fi

# Android TV Play Store images have historically only shipped for x86/x86_64
# — list what's actually offered and pick the newest matching API level
# rather than hardcoding a package string that may not exist any more.
AVAILABLE="$("$SDKMANAGER" --list 2>/dev/null | grep -E 'system-images;android-[0-9]+;(google_atv|android-tv)_playstore;' || true)"
IMAGE="$(echo "$AVAILABLE" | grep "$PREFERRED_ABI" | sort -t';' -k2 -V | tail -n1 | awk '{print $1}' || true)"
if [ -z "$IMAGE" ]; then
  IMAGE="$(echo "$AVAILABLE" | grep 'x86_64' | sort -t';' -k2 -V | tail -n1 | awk '{print $1}' || true)"
  [ -n "$IMAGE" ] && echo "  No $PREFERRED_ABI Android TV + Play Store image is published — falling back to x86_64 (runs under translation on Apple Silicon, slower but functional for reaching a login screen)."
fi
if [ -z "$IMAGE" ]; then
  cat <<'EOF'

  No Android TV + Play Store system image is available at all right now.
  Falling back to a regular PHONE profile with Play Store instead — the
  Boosteroid TV app may still install and run on it (Play sometimes hides
  TV-only apps on phone form factors; if so, we'll sideload the APK instead
  once you've pulled it from your own device with the app already on it).
EOF
  IMAGE="$(echo "$("$SDKMANAGER" --list 2>/dev/null | grep -E 'system-images;android-[0-9]+;google_apis_playstore;' )" | grep "$PREFERRED_ABI" | sort -t';' -k2 -V | tail -n1 | awk '{print $1}' || true)"
fi
[ -n "$IMAGE" ] || die "No Play-Store-capable system image found at all. Open Android Studio's SDK Manager and install one manually (look for 'Google Play' images), then re-run this script."
echo "  Using: $IMAGE"

log "Installing that system image (this downloads a few GB — grab a coffee)"
yes | "$SDKMANAGER" --install "$IMAGE" "platform-tools" "emulator" >/dev/null

ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
EMULATOR_BIN="$ANDROID_SDK_ROOT/emulator/emulator"

# ---------------------------------------------------------------------------
log "Creating the AVD (if it doesn't already exist)"
if ! "$AVDMANAGER" list avd | grep -q "Name: $AVD_NAME"; then
  DEVICE_PROFILE="tv_1080p"
  "$AVDMANAGER" list device | grep -q "$DEVICE_PROFILE" || DEVICE_PROFILE="pixel_4"
  echo "no" | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$IMAGE" -d "$DEVICE_PROFILE" --force
else
  echo "  AVD '$AVD_NAME' already exists — reusing it."
fi

# ---------------------------------------------------------------------------
log "Booting the emulator"
"$EMULATOR_BIN" -avd "$AVD_NAME" -no-snapshot-load -http-proxy "http://127.0.0.1:$MITM_PORT" >/tmp/boosteroid-emulator.log 2>&1 &
EMULATOR_PID=$!
echo "  Emulator PID: $EMULATOR_PID (log: /tmp/boosteroid-emulator.log)"

"$ADB" wait-for-device
echo "  Waiting for Android to finish booting..."
until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  sleep 2
done
echo "  Booted."

# ---------------------------------------------------------------------------
log "Starting mitmproxy in the background (web UI at http://127.0.0.1:$MITM_WEB_PORT)"
FILTER_SCRIPT="$CAPTURE_DIR/boosteroid_filter.py"
CAPTURE_FILE="$CAPTURE_FILE" mitmweb \
  --listen-port "$MITM_PORT" \
  --web-port "$MITM_WEB_PORT" \
  --web-open-browser \
  -s "$FILTER_SCRIPT" \
  >/tmp/boosteroid-mitmweb.log 2>&1 &
MITM_PID=$!
echo "  mitmweb PID: $MITM_PID (log: /tmp/boosteroid-mitmweb.log)"
sleep 2

# ---------------------------------------------------------------------------
log "Pointing the emulator's system-wide proxy at mitmproxy"
"$ADB" shell settings put global http_proxy "10.0.2.2:$MITM_PORT"

# ---------------------------------------------------------------------------
log "Fetching mitmproxy's CA certificate and pushing it to the device"
curl -fsSL http://127.0.0.1:8081 >/dev/null 2>&1 || true   # nudge mitmweb to be ready
curl -fsSL "http://mitm.it/cert/pem" -o "$CERT_PEM" 2>/dev/null || cp "$HOME/.mitmproxy/mitmproxy-ca-cert.pem" "$CERT_PEM"
"$ADB" push "$CERT_PEM" /sdcard/Download/mitmproxy-ca.crt

pause "On the emulator screen: open Settings > Security > Encryption & credentials > Install a certificate > CA certificate, then pick mitmproxy-ca.crt from Downloads and confirm the warning. This one tap is an Android security requirement I can't script around."

# ---------------------------------------------------------------------------
log "Opening the Play Store"
"$ADB" shell am start -a android.intent.action.VIEW -d "market://search?q=boosteroid" >/dev/null 2>&1 || \
  "$ADB" shell monkey -p com.android.vending -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

pause "Sign in with your Google account in the Play Store (I never see or touch this — do it directly on the emulator), then install 'Boosteroid Cloud Gaming TV'."

# ---------------------------------------------------------------------------
log "Launching Boosteroid"
"$ADB" shell monkey -p com.boosteroidtv.streaming -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || \
  echo "  Couldn't auto-launch by package name — open it manually from the emulator's app list."

pause "Navigate to the QR-code login screen inside the app. Once it's on screen, come back here and press Enter — the request that generated it should already be sitting in $CAPTURE_FILE."

log "Done. Captured Boosteroid-related requests:"
if [ -s "$CAPTURE_FILE" ]; then
  cat "$CAPTURE_FILE"
else
  echo "  (nothing captured yet — leave mitmweb running, retry the QR screen, then check $CAPTURE_FILE again)"
fi

cat <<EOF

Next step: share $CAPTURE_FILE with Claude (it's in the same folder as this
script) — that's the file to hand over for analysis. mitmweb's own UI is
still open at http://127.0.0.1:$MITM_WEB_PORT if you want to look through
everything yourself first.
EOF
