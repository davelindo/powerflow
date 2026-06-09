#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/xcode_env.sh"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DIR="${BUILD_DIR}/DerivedData"
APP_PATH="${DERIVED_DIR}/Build/Products/Release/Powerflow.app"
OUT_APP="${BUILD_DIR}/Powerflow.app"
OUT_DMG="${BUILD_DIR}/Powerflow.dmg"
OUT_ZIP="${BUILD_DIR}/Powerflow.zip"
REQUIRE_SIGNING="${POWERFLOW_REQUIRE_SIGNING:-0}"
SIGN_IDENTITY="${POWERFLOW_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${POWERFLOW_NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_KEYCHAIN="${POWERFLOW_NOTARY_KEYCHAIN:-}"
ENTITLEMENTS="${ROOT_DIR}/Resources/Powerflow.entitlements"

require_release_setting() {
  local name="$1"
  local value="$2"
  local purpose="$3"
  if [[ "$REQUIRE_SIGNING" == "1" && -z "$value" ]]; then
    echo "${name} is required for ${purpose}." >&2
    exit 1
  fi
}

build_app() {
  local build_args=(
    -project "${ROOT_DIR}/Powerflow.xcodeproj"
    -scheme Powerflow
    -configuration Release
    -destination "platform=macOS"
    -derivedDataPath "${DERIVED_DIR}"
  )

  if [[ -n "$SIGN_IDENTITY" ]]; then
    build_args+=(
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
      ENABLE_HARDENED_RUNTIME=YES
      OTHER_CODE_SIGN_FLAGS=--timestamp
    )
  fi

  xcodebuild "${build_args[@]}" build
}

copy_app() {
  rm -rf "${OUT_APP}"
  cp -R "${APP_PATH}" "${OUT_APP}"
}

sign_copied_app() {
  [[ -n "$SIGN_IDENTITY" ]] || return 0
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "${OUT_APP}"
  codesign --verify --deep --strict --verbose=2 "${OUT_APP}"
  codesign -d --entitlements :- "${OUT_APP}" >/dev/null
}

create_dmg() {
  rm -f "${OUT_DMG}"
  if diskutil image create -help >/dev/null 2>&1; then
    diskutil image create from \
      --format UDZO \
      --volumeName "Powerflow" \
      "${OUT_APP}" \
      "${OUT_DMG}" && return 0
    rm -f "${OUT_DMG}"
  fi

  hdiutil create \
    -volname "Powerflow" \
    -srcfolder "${OUT_APP}" \
    -ov \
    -format UDZO \
    "${OUT_DMG}"
}

create_zip_fallback() {
  if [[ "$REQUIRE_SIGNING" == "1" ]]; then
    echo "DMG creation failed; refusing to publish fallback artifact in release mode." >&2
    exit 1
  fi
  rm -f "${OUT_ZIP}"
  ditto -c -k --sequesterRsrc --keepParent "${OUT_APP}" "${OUT_ZIP}"
  echo "DMG creation failed; ZIP created instead."
  echo "ZIP: ${OUT_ZIP}"
}

notarize_dmg() {
  [[ -n "$NOTARY_PROFILE" ]] || return 0
  local notary_args=(--keychain-profile "$NOTARY_PROFILE")
  if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    notary_args+=(--keychain "$NOTARY_KEYCHAIN")
  fi
  xcrun notarytool submit "${OUT_DMG}" "${notary_args[@]}" --wait
  xcrun stapler staple "${OUT_DMG}"
  spctl --assess --type open --verbose "${OUT_DMG}"
}

require_release_setting "POWERFLOW_SIGN_IDENTITY" "$SIGN_IDENTITY" "release signing"
require_release_setting "POWERFLOW_NOTARY_KEYCHAIN_PROFILE" "$NOTARY_PROFILE" "release notarization"

mkdir -p "${BUILD_DIR}"
build_app
copy_app
sign_copied_app

if create_dmg; then
  echo "DMG: ${OUT_DMG}"
else
  create_zip_fallback
fi

notarize_dmg

echo "Release app: ${OUT_APP}"
