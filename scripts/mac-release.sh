#!/usr/bin/env bash
# Sign, notarize, staple, and zip a built macOS .app for distribution.
# Copy into a repo's scripts/ and run after the app bundle is built.
#
# Usage: mac-release.sh path/to/App.app [path/to/App.entitlements]
# Env:   SIGNING_IDENTITY  default: first "Developer ID Application" identity
#        NOTARY_PROFILE    notarytool keychain profile, default: notary
# Out:   App.zip next to App.app, plus its sha256 for a Homebrew cask.
set -euo pipefail

APP="${1:?usage: mac-release.sh App.app [App.entitlements]}"
ENTITLEMENTS="${2:-}"
APP="${APP%/}"
ZIP="${APP}.zip"

IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity in keychain." >&2; exit 1; }

echo "Signing with: $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-notary}" --wait
xcrun stapler staple "$APP"

# Re-zip so the download carries the stapled ticket.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute "$APP"

echo "Created: $ZIP"
echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
