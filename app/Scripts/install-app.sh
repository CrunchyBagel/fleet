#!/usr/bin/env bash
# Build the Fleet Mac app in Release and install it into /Applications.
#
# No signing or notarisation: the bundle is ad-hoc signed, which is all a local
# install needs. A locally built app carries no quarantine flag, so Gatekeeper
# stays quiet. The CLI is not touched; `fleet install` handles that.
#
# Usage: app/Scripts/install-app.sh [--no-open]
#   INSTALL_DIR=/somewhere   install there instead of /Applications
set -euo pipefail

PROJECT="Fleet.xcodeproj"
SCHEME="Fleet"
APP="Fleet.app"
BUNDLE_ID="com.crunchybagel.fleet"
BUILD_DIR="build"                 # gitignored in app/.gitignore
DEST_DIR="${INSTALL_DIR:-/Applications}"
OPEN_AFTER=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-open) OPEN_AFTER=0 ;;
    -h|--help) printf 'usage: %s [--no-open]\n' "$(basename "$0")"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."         # app/

# Fleet.xcodeproj is committed, so this never generates it. After editing
# project.yml, run `xcodegen generate` in app/ first.
echo "==> Building $SCHEME (Release)"
# Quiet on success, whole log on failure: xcodebuild is noisy even with -quiet,
# and prints a confusing "failed with exit code 0" line for builds that warn.
LOG="$(mktemp -t "$SCHEME-build")"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" build >"$LOG" 2>&1; then
  cat "$LOG" >&2
  rm -f "$LOG"
  exit 1
fi
rm -f "$LOG"

PRODUCT="$BUILD_DIR/Build/Products/Release/$APP"
if [ ! -d "$PRODUCT" ]; then
  printf 'build finished but %s is missing\n' "$PRODUCT" >&2
  exit 1
fi

# Only a copy running from the install destination blocks replacing it; a debug
# build running from .build is left alone.
running() { pgrep -f "$DEST_DIR/$APP/Contents/MacOS/" >/dev/null 2>&1; }

if running; then
  echo "==> Quitting the running copy"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  waited=0
  while running && [ "$waited" -lt 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
  done
  if running; then
    printf '%s is still running; quit it and run this again.\n' "$SCHEME" >&2
    exit 1
  fi
fi

echo "==> Installing into $DEST_DIR"
mkdir -p "$DEST_DIR"
rm -rf "${DEST_DIR:?}/$APP"
ditto "$PRODUCT" "$DEST_DIR/$APP"

printf 'Installed %s/%s\n' "$DEST_DIR" "$APP"
if [ "$OPEN_AFTER" -eq 1 ]; then
  open "$DEST_DIR/$APP"
fi
