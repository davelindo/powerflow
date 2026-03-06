#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

WALLPAPER_DIR="/tmp/powerflow-readme-assets"
mkdir -p "$WALLPAPER_DIR"

sips -s format png "/System/Library/Desktop Pictures/Sonoma.heic" --out "$WALLPAPER_DIR/sonoma.png" >/dev/null

scripts/update_layout_snapshots.sh

POWERFLOW_README_WALLPAPER_DIR="$WALLPAPER_DIR" swift scripts/render_readme_assets.swift
