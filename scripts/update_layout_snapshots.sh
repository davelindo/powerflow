#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
source "${ROOT_DIR}/scripts/xcode_env.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/powerflow-layout-snapshots.XXXXXX")"
DERIVED_DIR="${TMP_DIR}/DerivedData"
trap 'rm -rf "$TMP_DIR"' EXIT

xcodebuild \
  -project Powerflow.xcodeproj \
  -scheme Powerflow \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DIR" \
  OTHER_SWIFT_FLAGS="-DPOWERFLOW_RECORD_LAYOUT_SNAPSHOTS" \
  test \
  -only-testing:PowerflowTests/LayoutSnapshotTests
