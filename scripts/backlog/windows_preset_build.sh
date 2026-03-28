#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KABSD_GENERIC_WINDOWS_PRESET_IMPL="$SCRIPT_DIR/../windows/windows_preset_build.sh"
if [[ ! -f "$KABSD_GENERIC_WINDOWS_PRESET_IMPL" ]]; then
  echo "generic windows preset build script not found: $KABSD_GENERIC_WINDOWS_PRESET_IMPL" >&2
  exit 1
fi

export KABSD_BUILD_PREFIX="${KABSD_BUILD_PREFIX:-KOB}"
export KABSD_CMAKE_VAR_PREFIX="${KABSD_CMAKE_VAR_PREFIX:-KB}"

# shellcheck disable=SC1090
source "$KABSD_GENERIC_WINDOWS_PRESET_IMPL"
