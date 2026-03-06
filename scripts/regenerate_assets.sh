#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

scripts/update_layout_snapshots.sh

cp Tests/PowerflowTests/__Snapshots__/popover-dashboard-light.png assets/dashboard.png
cp Tests/PowerflowTests/__Snapshots__/history-section-light.png assets/graphs.png
cp Tests/PowerflowTests/__Snapshots__/popover-settings-light.png assets/settings.png
