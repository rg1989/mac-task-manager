#!/bin/bash
# Build this fork and install it to /Applications, signed with a local
# code-signing identity so macOS keeps the Full Disk Access grant across
# rebuilds (an ad-hoc signature changes on every build).
#
# Usage: ./scripts/fork-install.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Task Manager"
# The name this fork was installed under before it was renamed.
OLD_DEST="/Applications/Mac Sai.app"
APP_BUNDLE=".build/dmg/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
if [ -z "${IDENTITY}" ]; then
    echo "No code-signing identity found; the build will be ad-hoc signed and"
    echo "macOS will ask for Full Disk Access again after every install."
    BUILD_ARCHS="--arch $(uname -m)" ./scripts/build-dmg.sh --app-only
else
    echo "Signing with a local identity from the keychain."
    BUILD_ARCHS="--arch $(uname -m)" LOCAL_SIGNING_IDENTITY="${IDENTITY}" ./scripts/build-dmg.sh --app-only
fi

codesign --verify --deep --strict "${APP_BUNDLE}"

osascript -e "tell application id \"com.macclean.app\" to quit" >/dev/null 2>&1 || true
pkill -x MacCleanMenu 2>/dev/null || true
pkill -x MacClean 2>/dev/null || true
sleep 1

echo "Installing to ${DEST}..."
rm -rf "${DEST}" "${OLD_DEST}"
ditto "${APP_BUNDLE}" "${DEST}"
open "${DEST}"
echo "Installed. To return to the official app: brew install --cask mac-sai"
