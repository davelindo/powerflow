#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
source "${ROOT_DIR}/scripts/xcode_env.sh"

WALLPAPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/powerflow-readme-assets.XXXXXX")"
trap 'rm -rf "$WALLPAPER_DIR"' EXIT

sips -s format png "/System/Library/Desktop Pictures/Sonoma.heic" --out "$WALLPAPER_DIR/sonoma.png" >/dev/null

scripts/update_layout_snapshots.sh

POWERFLOW_README_WALLPAPER_DIR="$WALLPAPER_DIR" xcrun swift scripts/render_readme_assets.swift
