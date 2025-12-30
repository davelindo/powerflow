#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DIR="${BUILD_DIR}/DerivedData"
APP_PATH="${DERIVED_DIR}/Build/Products/Release/Powerflow.app"
OUT_APP="${BUILD_DIR}/Powerflow.app"
OUT_DMG="${BUILD_DIR}/Powerflow.dmg"
OUT_ZIP="${BUILD_DIR}/Powerflow.zip"

mkdir -p "${BUILD_DIR}"

xcodebuild \
  -project "${ROOT_DIR}/Powerflow.xcodeproj" \
  -scheme Powerflow \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "${DERIVED_DIR}" \
  build

rm -rf "${OUT_APP}"
cp -R "${APP_PATH}" "${OUT_APP}"

if hdiutil create \
  -volname "Powerflow" \
  -srcfolder "${OUT_APP}" \
  -ov \
  -format UDZO \
  "${OUT_DMG}"; then
  echo "DMG: ${OUT_DMG}"
else
  rm -f "${OUT_ZIP}"
  ditto -c -k --sequesterRsrc --keepParent "${OUT_APP}" "${OUT_ZIP}"
  echo "DMG creation failed; ZIP created instead."
  echo "ZIP: ${OUT_ZIP}"
fi

echo "Release app: ${OUT_APP}"
