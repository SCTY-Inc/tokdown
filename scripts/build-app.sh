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
swift build -c "$SWIFT_CONFIG"

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
cp "${PROJECT_DIR}/Sources/${TARGET_NAME}/Resources/TokDownIcon.svg" "${APP_BUNDLE_PATH}/Contents/Resources/" || true

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
