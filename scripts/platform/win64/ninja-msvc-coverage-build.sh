#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/windows_preset_build.sh"

kano_windows_run_preset "windows-ninja-msvc-coverage" "windows-ninja-msvc-coverage-debug" "x64"
