#!/usr/bin/env bash
#
# Builds a .ipa of BoosteroidATV.
#
#   ./scripts/build-ipa.sh              # unsigned  — for Sideloadly & friends
#   ./scripts/build-ipa.sh --signed     # signed    — needs a DEVELOPMENT_TEAM
#
# Unsigned is the default on purpose. Sideloadly (and any comparable tool)
# re-signs the app with whatever Apple ID the end user provides, so baking in a
# signature here would only be thrown away — and requiring one would mean every
# contributor needs a paid account just to produce a build.
#
# For --signed, pass your team id via the environment:
#   DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build-ipa.sh --signed
# The project deliberately does not hardcode a team (see Local.xcconfig.example).

set -euo pipefail

PROJECT="BoosteroidATV.xcodeproj"
SCHEME="BoosteroidATV"
APP_NAME="BoosteroidATV"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"

cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not found — this needs a Mac with Xcode installed." >&2
    exit 1
fi

SIGNED=false
[[ "${1:-}" == "--signed" ]] && SIGNED=true

if $SIGNED && [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "error: --signed needs a team id, e.g." >&2
    echo "       DEVELOPMENT_TEAM=ABCDE12345 $0 --signed" >&2
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving ($([ "$SIGNED" = true ] && echo signed || echo unsigned))"
if $SIGNED; then
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -sdk appletvos \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        -allowProvisioningUpdates
else
    # Skipping signing entirely keeps this runnable without any Apple account.
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -sdk appletvos \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGN_ENTITLEMENTS=""
fi

APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "error: no .app in the archive at $APP" >&2; exit 1; }

# An .ipa is just a zip with the .app inside a top-level Payload/ directory.
echo "==> Packaging"
rm -rf "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
( cd "$BUILD_DIR" && zip -qry "$APP_NAME.ipa" Payload )
rm -rf "$BUILD_DIR/Payload"

echo
echo "Done: $BUILD_DIR/$APP_NAME.ipa ($(du -h "$BUILD_DIR/$APP_NAME.ipa" | cut -f1))"
$SIGNED || echo "Unsigned — sideload it with a tool that signs using your own Apple ID."
