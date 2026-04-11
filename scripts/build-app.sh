#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

CONFIG="${1:-debug}"
TARGET_NAME="TokDown"
APP_NAME="TokDown"
APP_BUNDLE_NAME="${APP_NAME}.app"
APP_BUNDLE_PATH="${PROJECT_DIR}/${APP_BUNDLE_NAME}"
INFO_PLIST_SOURCE="${PROJECT_DIR}/Sources/${TARGET_NAME}/Resources/Info.plist"
ENTITLEMENTS_SOURCE="${PROJECT_DIR}/Sources/${TARGET_NAME}/Resources/${TARGET_NAME}.entitlements"

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

resolve_binary_path() {
  local binary=""
  for candidate in \
    "${PROJECT_DIR}/.build/arm64-apple-macosx/${SWIFT_CONFIG}/${TARGET_NAME}" \
    "${PROJECT_DIR}/.build/debug/${TARGET_NAME}" \
    "${PROJECT_DIR}/.build/release/${TARGET_NAME}" \
    "${PROJECT_DIR}/.build/${SWIFT_CONFIG}/${TARGET_NAME}"
  do
    if [[ -f "$candidate" ]]; then
      binary="$candidate"
      break
    fi
  done

  if [[ -z "$binary" ]]; then
    echo "Unable to locate built binary for ${TARGET_NAME}" >&2
    exit 1
  fi

  echo "$binary"
}

BINARY_PATH="$(resolve_binary_path)"

rm -rf "${APP_BUNDLE_PATH}"
mkdir -p "${APP_BUNDLE_PATH}/Contents/Resources"
mkdir -p "${APP_BUNDLE_PATH}/Contents/MacOS"
cp "$BINARY_PATH" "${APP_BUNDLE_PATH}/Contents/MacOS/${TARGET_NAME}"
cp "$INFO_PLIST_SOURCE" "${APP_BUNDLE_PATH}/Contents/Info.plist"
cp "${PROJECT_DIR}/Sources/${TARGET_NAME}/Resources/TokDownMenuIdle.svg" "${APP_BUNDLE_PATH}/Contents/Resources/" || true
cp "${PROJECT_DIR}/Sources/${TARGET_NAME}/Resources/TokDownMenuRecording.svg" "${APP_BUNDLE_PATH}/Contents/Resources/" || true
cp "${PROJECT_DIR}/Sources/${TARGET_NAME}/Resources/TokDownMenuTranscribing.svg" "${APP_BUNDLE_PATH}/Contents/Resources/" || true

# Generate .icns from app icon source (prefer PNG, fall back to SVG via qlmanage).
ICON_PNG="${PROJECT_DIR}/Sources/${TARGET_NAME}/Resources/TokDownIcon.png"
ICON_SVG="${PROJECT_DIR}/Sources/${TARGET_NAME}/Resources/TokDownIcon.svg"
ICONSET_DIR="${PROJECT_DIR}/.build/TokDown.iconset"
ICNS_FILE="${APP_BUNDLE_PATH}/Contents/Resources/TokDown.icns"
MASTER_PNG=""

if [[ -f "$ICON_PNG" ]]; then
  echo "Generating app icon (PNG source)..."
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  MASTER_PNG="${PROJECT_DIR}/.build/icon_master_1024.png"
  cp "$ICON_PNG" "$MASTER_PNG"
elif [[ -f "$ICON_SVG" ]]; then
  echo "Generating app icon (SVG source)..."
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  MASTER_PNG="${PROJECT_DIR}/.build/icon_master_1024.png"
  qlmanage -t -s 1024 -o "${PROJECT_DIR}/.build" "$ICON_SVG" >/dev/null 2>&1
  mv "${PROJECT_DIR}/.build/TokDownIcon.svg.png" "$MASTER_PNG"
fi

if [[ -n "$MASTER_PNG" && -f "$MASTER_PNG" ]]; then
  # Generate all required sizes for macOS .iconset
  for size in 16 32 128 256 512; do
    sips -z $size $size "$MASTER_PNG" --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null 2>&1
    double=$((size * 2))
    sips -z $double $double "$MASTER_PNG" --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null 2>&1
  done

  # Pack into .icns
  iconutil -c icns -o "$ICNS_FILE" "$ICONSET_DIR"
  rm -rf "$ICONSET_DIR" "$MASTER_PNG"
  echo "Generated: $ICNS_FILE"
fi

/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass string NSApplication" \
  "${APP_BUNDLE_PATH}/Contents/Info.plist" >/dev/null 2>&1 || true

echo "Signing ${APP_BUNDLE_NAME}..."
IDENTITY=$(security find-identity -v -p codesigning | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [[ -z "$IDENTITY" ]]; then
  echo "No signing identity found, using ad-hoc signing..."
  IDENTITY="-"
fi
echo "Signing with: ${IDENTITY}"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS_SOURCE" \
  --deep "${APP_BUNDLE_PATH}"

if [[ "$CONFIG" == "release" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE_PATH}" "${PROJECT_DIR}/${APP_BUNDLE_NAME}.zip"
  echo "Created: ${PROJECT_DIR}/${APP_BUNDLE_NAME}.zip"
fi

echo "Created: ${APP_BUNDLE_PATH}"
echo "Run with: open ${APP_BUNDLE_PATH}"
