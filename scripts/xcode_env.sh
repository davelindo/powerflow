#!/usr/bin/env bash

powerflow_configure_xcode() {
  if [[ -n "${POWERFLOW_DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="$POWERFLOW_DEVELOPER_DIR"
  elif [[ "${POWERFLOW_USE_XCODE_BETA:-0}" == "1" ]]; then
    local beta_developer_dir="/Applications/Xcode-beta.app/Contents/Developer"
    if [[ ! -d "$beta_developer_dir" ]]; then
      echo "POWERFLOW_USE_XCODE_BETA=1 was set, but Xcode-beta.app was not found." >&2
      exit 1
    fi
    export DEVELOPER_DIR="$beta_developer_dir"
  fi

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    echo "Using Xcode developer directory: $DEVELOPER_DIR" >&2
  fi
}

powerflow_configure_xcode
