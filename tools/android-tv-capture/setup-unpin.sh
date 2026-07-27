#!/usr/bin/env bash
#
# setup-unpin.sh — phase 2. setup.sh proved that Boosteroid's Android TV app
# talks to cloud.boosteroid.com but REJECTS mitmproxy's certificate
# (confirmed via repeated "TLS HANDSHAKE FAILED (client) sni=cloud.boosteroid.com"
# entries in all-hosts.log, right when the manual sign-in was attempted).
# That's certificate pinning: the app checks the server's cert/public key
# against a value baked into it, not just "is this CA trusted" — so
# installing mitmproxy's CA (what setup.sh already did) can never be enough
# on its own.
#
# The fix is runtime instrumentation: Frida, hooking the app's own
# TLS-validation code so it accepts ANY certificate, mitmproxy's included.
# That requires root, which Play-Store-flavored system images deliberately
# don't allow. So this script:
#   1. Pulls the already-installed Boosteroid APK off the ORIGINAL emulator
#      (the one setup.sh set up — must still be running, signed in, with
#      the app installed).
#   2. Boots a SECOND, separate AVD using a rootable "google_apis" image
#      (no Play Store needed here — we're sideloading the pulled APK
#      directly, never going through Play Store on this one).
#   3. Installs frida-server on that rooted device and frida-tools/objection
#      on this machine, matched by version and CPU ABI.
#   4. Spawns Boosteroid under Frida with a universal SSL-pinning bypass, so
#      the SAME mitmproxy instance from setup.sh can finally read the
#      plaintext of what it sends to cloud.boosteroid.com.
#
# Prerequisite: run setup.sh first and leave its emulator + mitmweb running.
#
# Run with:  bash setup-unpin.sh
#
set -uo pipefail   # NOT -e: several steps here (root, frida-server) are
                    # expected to sometimes fail on the first try and are
                    # retried explicitly instead of aborting the whole script.

CAPTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_FILE="$CAPTURE_DIR/boosteroid-capture.jsonl"
APK_PATH="$CAPTURE_DIR/boosteroid.apk"
UNPIN_AVD_BASE="BoosteroidTV-unpin"
MITM_PORT=8080
PACKAGE="com.boosteroidtv.streaming"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
pause() { printf '\n\033[1;33m--> %s\033[0m\n' "$1"; read -r -p "    Press Enter when done... " _; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1"; exit 1; }

# ---------------------------------------------------------------------------
log "Resolving Android SDK tools (same logic as setup.sh)"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
if [ ! -d "$ANDROID_SDK_ROOT" ]; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  [ -d "$BREW_PREFIX/share/android-commandlinetools" ] && ANDROID_SDK_ROOT="$BREW_PREFIX/share/android-commandlinetools"
fi
[ -d "$ANDROID_SDK_ROOT" ] || die "Couldn't find the Android SDK. Set \$ANDROID_SDK_ROOT and re-run."
export ANDROID_SDK_ROOT
export ANDROID_HOME="$ANDROID_SDK_ROOT"

ADB="$(find "$ANDROID_SDK_ROOT" -maxdepth 2 -name adb -type f 2>/dev/null | head -n1)"
SDKMANAGER="$(find "$ANDROID_SDK_ROOT" -name sdkmanager -type f 2>/dev/null | head -n1)"
AVDMANAGER="$(find "$ANDROID_SDK_ROOT" -name avdmanager -type f 2>/dev/null | head -n1)"
EMULATOR_BIN="$ANDROID_SDK_ROOT/emulator/emulator"
[ -n "$ADB" ] && [ -x "$ADB" ] || die "Couldn't find adb under $ANDROID_SDK_ROOT."
[ -x "$EMULATOR_BIN" ] || die "Couldn't find the emulator binary under $ANDROID_SDK_ROOT/emulator."
SDK_ROOT_FLAG="--sdk_root=$ANDROID_SDK_ROOT"

# ---------------------------------------------------------------------------
log "Checking for the original emulator (from setup.sh) with Boosteroid installed"
"$ADB" start-server >/dev/null 2>&1
N_DEVICES="$("$ADB" devices | grep -c "device$" || true)"
if [ "$N_DEVICES" -eq 0 ]; then
  die "No emulator/device connected. Boot the ORIGINAL emulator from setup.sh (the one signed into Google with Boosteroid installed) and leave it running, then re-run this script."
fi
if [ "$N_DEVICES" -gt 1 ]; then
  echo "  Multiple devices connected:"
  "$ADB" devices
  die "Set ANDROID_SERIAL to pick the ORIGINAL one (the signed-in emulator with Boosteroid installed), e.g.: ANDROID_SERIAL=emulator-5554 bash setup-unpin.sh"
fi

APK_REMOTE_PATH="$("$ADB" shell pm path "$PACKAGE" 2>/dev/null | tr -d '\r' | sed 's/^package://')"
[ -n "$APK_REMOTE_PATH" ] || die "Boosteroid ($PACKAGE) isn't installed on the currently-connected device. Make sure it's the original emulator from setup.sh, with the app already installed."
echo "  Found installed APK at: $APK_REMOTE_PATH"

log "Pulling the APK to $APK_PATH"
"$ADB" pull "$APK_REMOTE_PATH" "$APK_PATH" || die "adb pull failed."

SOURCE_ABI="$("$ADB" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
echo "  Source device ABI: $SOURCE_ABI"

# ---------------------------------------------------------------------------
log "Finding a rootable (non-Play-Store) 'google_apis' system image, same ABI"
"$SDKMANAGER" $SDK_ROOT_FLAG --list | tee /tmp/boosteroid-sdk-list.txt >/dev/null
# Deliberately NOT *_playstore and NOT google_atv — those images refuse
# `adb root`. Plain "google_apis" (phone/tablet shaped) images are rooted by
# default and are the standard target for this kind of instrumentation work.
# The Boosteroid APK still installs and launches fine via `adb install` even
# on a non-TV-shaped image — Play Store's TV-only visibility filtering
# doesn't apply to direct sideloading.
UNPIN_IMAGE=""
for api in 34 33 32 31 30; do
  UNPIN_IMAGE="$(grep -E "system-images;android-$api;google_apis;" /tmp/boosteroid-sdk-list.txt | grep "$SOURCE_ABI" | awk '{print $1}' | head -n1)"
  [ -n "$UNPIN_IMAGE" ] && break
done
[ -n "$UNPIN_IMAGE" ] || die "No rootable google_apis image found for ABI $SOURCE_ABI. Run: grep 'google_apis;' /tmp/boosteroid-sdk-list.txt   and pick one manually, then adjust this script's 'for api in ...' list."
echo "  Using: $UNPIN_IMAGE"

yes | "$SDKMANAGER" $SDK_ROOT_FLAG --install "$UNPIN_IMAGE" || true

UNPIN_AVD_NAME="${UNPIN_AVD_BASE}-${api}-${SOURCE_ABI}"
log "Creating the rooted AVD '$UNPIN_AVD_NAME' (if needed)"
if ! "$AVDMANAGER" list avd | grep -q "Name: $UNPIN_AVD_NAME"; then
  echo "no" | "$AVDMANAGER" create avd -n "$UNPIN_AVD_NAME" -k "$UNPIN_IMAGE" -d "pixel_4" --force
else
  echo "  AVD '$UNPIN_AVD_NAME' already exists — reusing it."
fi

# ---------------------------------------------------------------------------
log "Booting the rooted emulator (proxy on from the start — no Google sign-in happens here)"
"$EMULATOR_BIN" -avd "$UNPIN_AVD_NAME" -no-snapshot-load -http-proxy "http://127.0.0.1:$MITM_PORT" \
  >/tmp/boosteroid-unpin-emulator.log 2>&1 &
echo "  Emulator PID: $! (log: /tmp/boosteroid-unpin-emulator.log)"

"$ADB" wait-for-device
echo "  Waiting for boot..."
until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
echo "  Booted."

log "Getting root"
"$ADB" root
sleep 2
"$ADB" wait-for-device

log "Installing the pulled Boosteroid APK"
"$ADB" install -r "$APK_PATH" || die "adb install failed — the APK pulled from the source device may be split/multi-APK (Play Store sometimes installs as an app bundle, which a single 'pm path' + pull won't fully capture). If so, tell Claude — we'll need 'adb shell pm path --all-splits' instead."

# ---------------------------------------------------------------------------
log "Installing frida-tools + objection on this machine (if needed)"
command -v frida >/dev/null 2>&1 || pip3 install --break-system-packages frida-tools
command -v objection >/dev/null 2>&1 || pip3 install --break-system-packages objection

FRIDA_VER="$(frida --version 2>/dev/null | tr -d '\r')"
[ -n "$FRIDA_VER" ] || die "frida --version failed — pip install may have gone into a venv not on PATH. Run 'pip3 show frida-tools' to see where it landed."
echo "  Host frida-tools version: $FRIDA_VER"

case "$SOURCE_ABI" in
  arm64-v8a) FRIDA_ARCH="arm64" ;;
  x86_64)    FRIDA_ARCH="x86_64" ;;
  x86)       FRIDA_ARCH="x86" ;;
  armeabi-v7a) FRIDA_ARCH="arm" ;;
  *) die "Unrecognized ABI '$SOURCE_ABI' — pick the matching frida-server asset manually from https://github.com/frida/frida/releases/tag/$FRIDA_VER" ;;
esac

FRIDA_SERVER_XZ="/tmp/frida-server-$FRIDA_VER-android-$FRIDA_ARCH.xz"
FRIDA_SERVER_BIN="/tmp/frida-server-$FRIDA_VER-android-$FRIDA_ARCH"
if [ ! -f "$FRIDA_SERVER_BIN" ]; then
  log "Downloading frida-server $FRIDA_VER for android-$FRIDA_ARCH"
  curl -fL -o "$FRIDA_SERVER_XZ" \
    "https://github.com/frida/frida/releases/download/$FRIDA_VER/frida-server-$FRIDA_VER-android-$FRIDA_ARCH.xz" \
    || die "Download failed. Check https://github.com/frida/frida/releases/tag/$FRIDA_VER manually — the asset naming occasionally changes between releases."
  unxz -f "$FRIDA_SERVER_XZ" || die "unxz failed (brew install xz if missing)."
fi
chmod +x "$FRIDA_SERVER_BIN"

log "Pushing and starting frida-server on the device"
"$ADB" push "$FRIDA_SERVER_BIN" /data/local/tmp/frida-server || die "adb push frida-server failed."
"$ADB" shell "chmod 755 /data/local/tmp/frida-server"
"$ADB" shell "nohup /data/local/tmp/frida-server >/data/local/tmp/frida-server.log 2>&1 &" >/dev/null 2>&1
sleep 2
"$ADB" shell "ps -A 2>/dev/null | grep frida-server" || die "frida-server doesn't appear to be running. Check /data/local/tmp/frida-server.log on the device (adb shell cat /data/local/tmp/frida-server.log)."
echo "  frida-server is running."

# ---------------------------------------------------------------------------
log "Launching Boosteroid under Frida with SSL-pinning bypass"
cat <<'EOF'

  This opens objection's interactive console. Once you see its prompt
  (something like "com.boosteroidtv.streaming on ... [usb] # "), the app
  should already be starting on the emulator screen with pinning disabled.
  Navigate to the QR-code screen or try "Sign in Manually" there, THEN come
  back to this terminal and type:  exit
  to leave objection and continue this script.
EOF
objection -g "$PACKAGE" explore --startup-command "android sslpinning disable"

# ---------------------------------------------------------------------------
log "Done. Captured Boosteroid-related requests:"
if [ -s "$CAPTURE_FILE" ]; then
  cat "$CAPTURE_FILE"
else
  echo "  (still nothing captured — check /tmp/boosteroid-unpin-emulator.log and this device's all-hosts.log entries; if TLS handshake failures for cloud.boosteroid.com have stopped appearing but no request shows up either, pinning is bypassed but the app may be hitting a slightly different host — check the widened all-hosts.log)"
fi

cat <<EOF

If this worked, $CAPTURE_FILE now has the real QR-login request(s). Share
it with Claude the same way as before.
EOF
