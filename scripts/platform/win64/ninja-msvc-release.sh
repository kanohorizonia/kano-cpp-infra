#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../lib/native_tool.sh"
kano_cpp_infra_watchdog_enter "$0" "$@"

source "$SCRIPT_DIR/../../lib/windows_preset_build.sh"

kano_windows_run_preset \
  "${KANO_WINDOWS_CONFIGURE_PRESET:-windows-ninja-msvc}" \
  "${KANO_WINDOWS_BUILD_PRESET:-windows-ninja-msvc-release}" \
  "${KANO_WINDOWS_VCVARS_ARCH:-x64}"
