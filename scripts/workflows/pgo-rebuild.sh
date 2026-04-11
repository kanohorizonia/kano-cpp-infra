#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"
COMMON_ROOT="$CPP_ROOT/shared/infra/scripts/common"
STAGES_ROOT="$CPP_ROOT/shared/infra/scripts/stages"

BUILD_METADATA_SH="$COMMON_ROOT/build_metadata.sh"
UNIX_PRESET_BUILD_SH="$COMMON_ROOT/unix_preset_build.sh"
WINDOWS_PRESET_BUILD_SH="$COMMON_ROOT/windows_preset_build.sh"
PGO_GATHER_SH="$STAGES_ROOT/pgo-gather.sh"
PGO_WORKFLOW_SH="$COMMON_ROOT/pgo_workflow.sh"

require_file() {
  local in_path="$1"
  if [[ ! -f "$in_path" ]]; then
    echo "Required script not found: $in_path" >&2
    exit 1
  fi
}

json_with_pgo_mode() {
  local in_mode="$1"
  python - "$in_mode" <<'PY'
import json
import os
import sys

mode = sys.argv[1]
raw = (os.environ.get("KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON") or "").strip()
data = {}
if raw:
    data = json.loads(raw)
data["KANO_CPP_INFRA_PGO_MODE"] = mode
print(json.dumps(data))
PY
}

cmake_preset_exists() {
  local preset_name="$1"
  python - "$CPP_ROOT/CMakePresets.json" "$preset_name" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
name = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
presets = []
for section in ("configurePresets", "buildPresets"):
    presets.extend(str(item.get("name", "")) for item in data.get(section, []))
raise SystemExit(0 if name in presets else 1)
PY
}

first_existing_preset() {
  local candidate
  for candidate in "$@"; do
    if [[ -n "$candidate" ]] && cmake_preset_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

is_windows_host() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

is_macos_host() {
  [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]
}

default_collect_configure_preset() {
  if is_windows_host; then
    first_existing_preset windows-ninja-msvc-pgo-collect windows-ninja-msvc windows-ninja-clang-pgo-collect windows-ninja-clang
  elif is_macos_host; then
    if [[ "$(uname -m 2>/dev/null || true)" == "arm64" || "$(uname -m 2>/dev/null || true)" == "aarch64" ]]; then
      first_existing_preset macos-ninja-clang-arm64-pgo-collect macos-ninja-clang-arm64 macos-ninja-clang-pgo-collect macos-ninja-clang
    else
      first_existing_preset macos-ninja-clang-x64-pgo-collect macos-ninja-clang-x64 macos-ninja-clang-pgo-collect macos-ninja-clang
    fi
  else
    first_existing_preset linux-ninja-gcc-pgo-collect linux-ninja-gcc linux-ninja-clang-pgo-collect linux-ninja-clang
  fi
}

default_collect_build_preset() {
  if is_windows_host; then
    first_existing_preset windows-ninja-msvc-pgo-collect-debug windows-ninja-msvc-debug windows-ninja-clang-pgo-collect-debug windows-ninja-clang-debug
  elif is_macos_host; then
    if [[ "$(uname -m 2>/dev/null || true)" == "arm64" || "$(uname -m 2>/dev/null || true)" == "aarch64" ]]; then
      first_existing_preset macos-ninja-clang-arm64-pgo-collect-debug macos-ninja-clang-arm64-debug macos-ninja-clang-pgo-collect-debug macos-ninja-clang-debug
    else
      first_existing_preset macos-ninja-clang-x64-pgo-collect-debug macos-ninja-clang-x64-debug macos-ninja-clang-pgo-collect-debug macos-ninja-clang-debug
    fi
  else
    first_existing_preset linux-ninja-gcc-pgo-collect-debug linux-ninja-gcc-debug linux-ninja-clang-pgo-collect-debug linux-ninja-clang-debug
  fi
}

default_use_configure_preset() {
  if is_windows_host; then
    first_existing_preset windows-ninja-msvc-pgo-use windows-ninja-msvc windows-ninja-clang-pgo-use windows-ninja-clang
  elif is_macos_host; then
    if [[ "$(uname -m 2>/dev/null || true)" == "arm64" || "$(uname -m 2>/dev/null || true)" == "aarch64" ]]; then
      first_existing_preset macos-ninja-clang-arm64-pgo-use macos-ninja-clang-arm64 macos-ninja-clang-pgo-use macos-ninja-clang
    else
      first_existing_preset macos-ninja-clang-x64-pgo-use macos-ninja-clang-x64 macos-ninja-clang-pgo-use macos-ninja-clang
    fi
  else
    first_existing_preset linux-ninja-gcc-pgo-use linux-ninja-gcc linux-ninja-clang-pgo-use linux-ninja-clang
  fi
}

default_use_build_preset() {
  if is_windows_host; then
    first_existing_preset windows-ninja-msvc-pgo-use-release windows-ninja-msvc-release windows-ninja-clang-pgo-use-release windows-ninja-clang-release
  elif is_macos_host; then
    if [[ "$(uname -m 2>/dev/null || true)" == "arm64" || "$(uname -m 2>/dev/null || true)" == "aarch64" ]]; then
      first_existing_preset macos-ninja-clang-arm64-pgo-use-release macos-ninja-clang-arm64-release macos-ninja-clang-pgo-use-release macos-ninja-clang-release
    else
      first_existing_preset macos-ninja-clang-x64-pgo-use-release macos-ninja-clang-x64-release macos-ninja-clang-pgo-use-release macos-ninja-clang-release
    fi
  else
    first_existing_preset linux-ninja-gcc-pgo-use-release linux-ninja-gcc-release linux-ninja-clang-pgo-use-release linux-ninja-clang-release
  fi
}

run_collect_build() {
  local configure_preset="${KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET:-$(default_collect_configure_preset)}"
  local build_preset="${KANO_CPP_INFRA_PGO_COLLECT_BUILD_PRESET:-$(default_collect_build_preset)}"
  local original_cache_args="${KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON:-}"

  export KANO_CPP_INFRA_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON="$(json_with_pgo_mode collect)"

  if is_windows_host; then
    # shellcheck disable=SC1090
    source "$BUILD_METADATA_SH"
    # shellcheck disable=SC1090
    source "$WINDOWS_PRESET_BUILD_SH"
    kano_cpp_infra_run_windows_preset "$configure_preset" "$build_preset" "${KANO_CPP_INFRA_VCVARS_ARCH:-x64}"
  else
    # shellcheck disable=SC1090
    source "$UNIX_PRESET_BUILD_SH"
    kano_cpp_infra_run_unix_preset "$configure_preset" "$build_preset"
  fi

  export KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON="$original_cache_args"
}

run_use_build() {
  local configure_preset="${KANO_CPP_INFRA_PGO_USE_CONFIGURE_PRESET:-$(default_use_configure_preset)}"
  local build_preset="${KANO_CPP_INFRA_PGO_USE_BUILD_PRESET:-$(default_use_build_preset)}"
  local original_cache_args="${KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON:-}"

  export KANO_CPP_INFRA_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON="$(json_with_pgo_mode use)"

  if is_windows_host; then
    # shellcheck disable=SC1090
    source "$BUILD_METADATA_SH"
    # shellcheck disable=SC1090
    source "$WINDOWS_PRESET_BUILD_SH"
    kano_cpp_infra_run_windows_preset "$configure_preset" "$build_preset" "${KANO_CPP_INFRA_VCVARS_ARCH:-x64}"
  else
    # shellcheck disable=SC1090
    source "$UNIX_PRESET_BUILD_SH"
    kano_cpp_infra_run_unix_preset "$configure_preset" "$build_preset"
  fi

  export KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON="$original_cache_args"
}

main() {
  require_file "$BUILD_METADATA_SH"
  require_file "$UNIX_PRESET_BUILD_SH"
  require_file "$WINDOWS_PRESET_BUILD_SH"
  require_file "$PGO_GATHER_SH"
  require_file "$PGO_WORKFLOW_SH"

  run_collect_build
  bash "$PGO_GATHER_SH"
  bash "$PGO_WORKFLOW_SH" merge
  run_use_build
}

main "$@"
