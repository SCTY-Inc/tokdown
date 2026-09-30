#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

CONFIG="${1:-debug}"
TARGET_NAME="TokDown"
APP_NAME="TokDown"
APP_BUNDLE_NAME="${APP_NAME}.app"
APP_BUNDLE_PATH="${PROJECT_DIR}/${APP_BUNDLE_NAME}"
INFO_PLIST_SOURCE="${PROJECT_DIR}/macOS/Resources/Info.plist"
ENTITLEMENTS_SOURCE="${PROJECT_DIR}/macOS/Resources/${TARGET_NAME}.entitlements"

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
  echo "Usage: ./scripts/build-app.sh [debug|release]" >&2
  exit 1
fi

SWIFT_CONFIG="${CONFIG}"
echo "Building ${TARGET_NAME} (${SWIFT_CONFIG})..."
# Pipe through xcbeautify for parseable output when available (graceful fallback to cat).
# set -o pipefail above ensures swift build failures still propagate through the pipe. [Rule 11]
if command -v xcbeautify >/dev/null 2>&1; then
  swift build -c "$SWIFT_CONFIG" 2>&1 | xcbeautify
else
  swift build -c "$SWIFT_CONFIG"
fi

BINARY_PATH="$(swift build -c "$SWIFT_CONFIG" --show-bin-path)/${TARGET_NAME}"

rm -rf "${APP_BUNDLE_PATH}"
mkdir -p "${APP_BUNDLE_PATH}/Contents/Resources"
mkdir -p "${APP_BUNDLE_PATH}/Contents/MacOS"
cp "$BINARY_PATH" "${APP_BUNDLE_PATH}/Contents/MacOS/${TARGET_NAME}"
cp "$INFO_PLIST_SOURCE" "${APP_BUNDLE_PATH}/Contents/Info.plist"

# Generate .icns from the 1024px PNG icon source.
ICON_PNG="${PROJECT_DIR}/macOS/Resources/TokDownIcon.png"
ICONSET_DIR="${PROJECT_DIR}/.build/TokDown.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_PNG" --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$ICON_PNG" --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "${APP_BUNDLE_PATH}/Contents/Resources/TokDown.icns" "$ICONSET_DIR"
rm -rf "$ICONSET_DIR"

echo "Signing ${APP_BUNDLE_NAME}..."
mapfile -t IDENTITIES < <(security find-identity -v -p codesigning | sed -n 's/.*"\(.*\)".*/\1/p')

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  IDENTITY="${SIGNING_IDENTITY}"
elif [[ ${#IDENTITIES[@]} -eq 0 ]]; then
  echo "No signing identity found, using ad-hoc signing..."
  IDENTITY="-"
elif [[ ${#IDENTITIES[@]} -eq 1 ]]; then
  IDENTITY="${IDENTITIES[0]}"
else
  echo "Multiple signing identities found. Set SIGNING_IDENTITY to choose explicitly." >&2
  printf '  - %s\n' "${IDENTITIES[@]}" >&2
  IDENTITY="${IDENTITIES[0]}"
  echo "Defaulting to first identity: ${IDENTITY}" >&2
fi

echo "Signing with: ${IDENTITY}"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS_SOURCE" "${APP_BUNDLE_PATH}"

echo "Created: ${APP_BUNDLE_PATH}"
echo "Run with: open ${APP_BUNDLE_PATH}"
