#!/usr/bin/env bash
#
# Builds a .ipa of BoosteroidATV.
#
#   ./scripts/build-ipa.sh              # unsigned  — for Sideloadly & friends
#   ./scripts/build-ipa.sh --signed     # signed    — needs a DEVELOPMENT_TEAM
#
# Versioning is calendar-based (YYYY.MM.DD), stamped from today's date, so a
# build always carries the same version as the release tag it goes out under
# and nothing has to be bumped by hand. Override it when cutting a second
# release on the same day, or when rebuilding an older tag:
#
#   VERSION=2026.08.10.1 ./scripts/build-ipa.sh
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

# YYYY.MM.DD for the user-visible version; the build number has to be plain
# digits, so it's the same date without separators.
VERSION="${VERSION:-$(date +%Y.%m.%d)}"
BUILD_NUMBER="$(echo "$VERSION" | tr -d '.')"
IPA="$BUILD_DIR/$APP_NAME-$VERSION.ipa"

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

echo "==> Archiving $VERSION ($([ "$SIGNED" = true ] && echo signed || echo unsigned))"
if $SIGNED; then
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -sdk appletvos \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
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
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
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
( cd "$BUILD_DIR" && zip -qry "$(basename "$IPA")" Payload )
rm -rf "$BUILD_DIR/Payload"

echo
echo "Done: $IPA ($(du -h "$IPA" | cut -f1))"
$SIGNED || echo "Unsigned — sideload it with a tool that signs using your own Apple ID."
echo
echo "To release it:"
echo "  git tag -a $VERSION -m \"$VERSION\" && git push origin $VERSION"
echo "  then attach $IPA to the GitHub release for that tag"
