#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../windows_preset_build.sh"

kabsd_run_windows_preset "windows-ninja-msvc" "windows-ninja-msvc-release" "x64"
