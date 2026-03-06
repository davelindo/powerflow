#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MODE_FILE="/tmp/powerflow-layout-snapshot-mode"
trap 'rm -f "$MODE_FILE"' EXIT
printf 'verify\n' > "$MODE_FILE"

xcodebuild \
  -project Powerflow.xcodeproj \
  -scheme Powerflow \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/powerflow-layout-snapshots-derived \
  test \
  -only-testing:PowerflowTests/LayoutSnapshotTests
