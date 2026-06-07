#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"
LIB_ROOT="$CPP_ROOT/shared/infra/scripts/lib"
STAGES_ROOT="$CPP_ROOT/shared/infra/scripts/stages"

BUILD_METADATA_SH="$LIB_ROOT/build_metadata.sh"
UNIX_PRESET_BUILD_SH="$LIB_ROOT/unix_preset_build.sh"
WINDOWS_PRESET_BUILD_SH="$LIB_ROOT/windows_preset_build.sh"
PGO_GATHER_SH="$STAGES_ROOT/pgo-gather.sh"
PGO_WORKFLOW_SH="$LIB_ROOT/pgo_workflow.sh"
PROFILE_MANIFEST_SH="$STAGES_ROOT/profile-run-manifest.sh"

resolve_python_bin() {
  if [[ -n "${KANO_PYTHON:-}" ]]; then
    printf '%s\n' "$KANO_PYTHON"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi

  echo "python3 or python is required." >&2
  return 1
}

PYTHON_BIN="$(resolve_python_bin)"

require_file() {
  local in_path="$1"
  if [[ ! -f "$in_path" ]]; then
    echo "Required script not found: $in_path" >&2
    exit 1
  fi
}

json_with_pgo_mode() {
  local in_mode="$1"
  "$PYTHON_BIN" - "$in_mode" <<'PY'
import json
import os
import sys

mode = sys.argv[1]
raw = (os.environ.get("KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON") or "").strip()
data = {}
if raw:
    data = json.loads(raw)
data["KANO_CPP_INFRA_PGO_MODE"] = mode
if mode == "use":
  data.setdefault("KOG_BUILD_TESTS", "OFF")
print(json.dumps(data))
PY
}

cmake_preset_exists() {
  local preset_name="$1"
  [[ -f "$CPP_ROOT/CMakePresets.json" ]] || return 1
  "$PYTHON_BIN" - "$CPP_ROOT/CMakePresets.json" "$preset_name" <<'PY'
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

default_coverage_configure_preset() {
  if is_windows_host; then
    first_existing_preset windows-ninja-msvc-coverage windows-ninja-msvc
  elif is_macos_host; then
    if [[ "$(uname -m 2>/dev/null || true)" == "arm64" || "$(uname -m 2>/dev/null || true)" == "aarch64" ]]; then
      first_existing_preset macos-ninja-clang-arm64-coverage macos-ninja-clang-coverage macos-ninja-clang-arm64 macos-ninja-clang
    else
      first_existing_preset macos-ninja-clang-x64-coverage macos-ninja-clang-coverage macos-ninja-clang-x64 macos-ninja-clang
    fi
  else
    first_existing_preset linux-ninja-clang-coverage linux-ninja-gcc-coverage linux-ninja-clang linux-ninja-gcc
  fi
}

default_coverage_build_preset() {
  if is_windows_host; then
    first_existing_preset windows-ninja-msvc-coverage-debug windows-ninja-msvc-debug
  elif is_macos_host; then
    if [[ "$(uname -m 2>/dev/null || true)" == "arm64" || "$(uname -m 2>/dev/null || true)" == "aarch64" ]]; then
      first_existing_preset macos-ninja-clang-arm64-coverage-debug macos-ninja-clang-coverage-debug macos-ninja-clang-arm64-debug macos-ninja-clang-debug
    else
      first_existing_preset macos-ninja-clang-x64-coverage-debug macos-ninja-clang-coverage-debug macos-ninja-clang-x64-debug macos-ninja-clang-debug
    fi
  else
    first_existing_preset linux-ninja-clang-coverage-debug linux-ninja-gcc-coverage-debug linux-ninja-clang-debug linux-ninja-gcc-debug
  fi
}

default_collect_configure_preset() {
  if is_windows_host; then
    first_existing_preset windows-ninja-msvc-pgo-collect windows-ninja-msvc windows-ninja-clang-pgo-collect windows-ninja-clang
  elif is_macos_host; then
    if [[ "$(uname -m 2>/dev/null || true)" == "arm64" || "$(uname -m 2>/dev/null || true)" == "aarch64" ]]; then
      first_existing_preset macos-ninja-clang-arm64-pgo-collect macos-ninja-clang-pgo-collect macos-ninja-clang-arm64 macos-ninja-clang
    else
      first_existing_preset macos-ninja-clang-x64-pgo-collect macos-ninja-clang-pgo-collect macos-ninja-clang-x64 macos-ninja-clang
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
      first_existing_preset macos-ninja-clang-arm64-pgo-collect-debug macos-ninja-clang-pgo-collect-debug macos-ninja-clang-arm64-debug macos-ninja-clang-debug
    else
      first_existing_preset macos-ninja-clang-x64-pgo-collect-debug macos-ninja-clang-pgo-collect-debug macos-ninja-clang-x64-debug macos-ninja-clang-debug
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
      first_existing_preset macos-ninja-clang-arm64-pgo-use macos-ninja-clang-pgo-use macos-ninja-clang-arm64 macos-ninja-clang
    else
      first_existing_preset macos-ninja-clang-x64-pgo-use macos-ninja-clang-pgo-use macos-ninja-clang-x64 macos-ninja-clang
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
      first_existing_preset macos-ninja-clang-arm64-pgo-use-release macos-ninja-clang-pgo-use-release macos-ninja-clang-arm64-release macos-ninja-clang-release
    else
      first_existing_preset macos-ninja-clang-x64-pgo-use-release macos-ninja-clang-pgo-use-release macos-ninja-clang-x64-release macos-ninja-clang-release
    fi
  else
    first_existing_preset linux-ninja-gcc-pgo-use-release linux-ninja-gcc-release linux-ninja-clang-pgo-use-release linux-ninja-clang-release
  fi
}

pgo_compiler_id_for_preset() {
  local preset="${1:-}"
  case "$preset" in
    *msvc*) printf '%s\n' "MSVC" ;;
    *gcc*) printf '%s\n' "GNU" ;;
    *clang*) printf '%s\n' "Clang" ;;
    *) printf '%s\n' "" ;;
  esac
}

remove_build_tree_for_reconfigure() {
  local in_path="$1"
  [[ -n "$in_path" ]] || return 0
  [[ -d "$in_path" ]] || return 0

  local trash_path="${in_path}.delete-$RANDOM-$$"
  if mv "$in_path" "$trash_path" 2>/dev/null; then
    local attempt
    for attempt in 1 2 3; do
      chmod -R u+w "$trash_path" 2>/dev/null || true
      if rm -rf "$trash_path" 2>/dev/null; then
        return 0
      fi
      sleep "$attempt"
    done
    echo "[pgo] warning: stale build dir moved aside but not fully deleted: $trash_path" >&2
    return 0
  fi

  local attempt
  for attempt in 1 2 3; do
    chmod -R u+w "$in_path" 2>/dev/null || true
    if rm -rf "$in_path" 2>/dev/null; then
      return 0
    fi
    sleep "$attempt"
  done

  if [[ -d "$in_path" ]]; then
    echo "[pgo] failed to clean stale build dir: $in_path" >&2
    return 1
  fi
}

run_collect_build() {
  local configure_preset="${KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET:-$(default_collect_configure_preset)}"
  local build_preset="${KANO_CPP_INFRA_PGO_COLLECT_BUILD_PRESET:-$(default_collect_build_preset)}"
  local original_cache_args="${KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON:-}"

  export KANO_CPP_INFRA_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET="$configure_preset"
  if is_windows_host; then
    export INF_PGO_COLLECT_DIR="$CPP_ROOT/out/bin/$configure_preset/debug"
  else
    export INF_PGO_COLLECT_DIR="$CPP_ROOT/out/obj/$configure_preset"
  fi
  if is_windows_host; then
    export KANO_CPP_INFRA_PGO_COMPILER_ID="MSVC"
  else
    local compiler_id
    compiler_id="$(pgo_compiler_id_for_preset "$configure_preset")"
    if [[ -n "$compiler_id" ]]; then
      export KANO_CPP_INFRA_PGO_COMPILER_ID="$compiler_id"
    fi
  fi
  export KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON="$(json_with_pgo_mode collect)"

  # Clean the pgo-collect build dir to ensure MSVC is used (not a stale MinGW cache)
  local collect_obj_dir="$CPP_ROOT/out/obj/$configure_preset"
  if [[ -d "$collect_obj_dir" ]]; then
    echo "[pgo] cleaning stale collect build dir: $collect_obj_dir" >&2
    remove_build_tree_for_reconfigure "$collect_obj_dir"
  fi

  if is_windows_host; then
    # shellcheck disable=SC1090
    source "$WINDOWS_PRESET_BUILD_SH"
    kano_windows_run_preset "$configure_preset" "$build_preset" "${KANO_CPP_INFRA_VCVARS_ARCH:-x64}"
  else
    # shellcheck disable=SC1090
    source "$UNIX_PRESET_BUILD_SH"
    kano_cpp_run_unix_preset "$configure_preset" "$build_preset"
  fi

  export KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON="$original_cache_args"
}

run_use_build() {
  local configure_preset="${KANO_CPP_INFRA_PGO_USE_CONFIGURE_PRESET:-$(default_use_configure_preset)}"
  local build_preset="${KANO_CPP_INFRA_PGO_USE_BUILD_PRESET:-$(default_use_build_preset)}"
  local original_cache_args="${KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON:-}"

  export KANO_CPP_INFRA_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_ROOT="$CPP_ROOT"
  if is_windows_host; then
    export KANO_CPP_INFRA_PGO_COMPILER_ID="MSVC"
  fi
  export KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON="$(json_with_pgo_mode use)"

  if is_windows_host; then
    # shellcheck disable=SC1090
    source "$WINDOWS_PRESET_BUILD_SH"
    kano_windows_run_preset "$configure_preset" "$build_preset" "${KANO_CPP_INFRA_VCVARS_ARCH:-x64}"
  else
    # shellcheck disable=SC1090
    source "$UNIX_PRESET_BUILD_SH"
    kano_cpp_run_unix_preset "$configure_preset" "$build_preset"
  fi

  export KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON="$original_cache_args"
}

prepare_pgo_collect_environment() {
  local configure_preset="${KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET:-$(default_collect_configure_preset)}"

  export KANO_CPP_INFRA_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET="$configure_preset"
  if is_windows_host; then
    export INF_PGO_COLLECT_DIR="$CPP_ROOT/out/bin/$configure_preset/debug"
    export KANO_CPP_INFRA_PGO_COMPILER_ID="MSVC"
  else
    export INF_PGO_COLLECT_DIR="$CPP_ROOT/out/obj/$configure_preset"
    local compiler_id
    compiler_id="$(pgo_compiler_id_for_preset "$configure_preset")"
    if [[ -n "$compiler_id" ]]; then
      export KANO_CPP_INFRA_PGO_COMPILER_ID="$compiler_id"
    fi
  fi
}

copy_msvc_pgd_to_use_dir() {
  if ! is_windows_host; then
    return 0
  fi

  local collect_preset="${KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET:-$(default_collect_configure_preset)}"
  local use_preset="${KANO_CPP_INFRA_PGO_USE_CONFIGURE_PRESET:-$(default_use_configure_preset)}"
  local collect_dir="$CPP_ROOT/out/bin/$collect_preset/debug"
  local use_dir="$CPP_ROOT/out/bin/$use_preset/release"

  if [[ ! -d "$collect_dir" ]]; then
    echo "[pgo] collect profile dir missing: $collect_dir" >&2
    return 1
  fi

  mkdir -p "$use_dir"

  local copied=0
  local pgd
  shopt -s nullglob
  for pgd in "$collect_dir"/*.pgd; do
    cp -f "$pgd" "$use_dir/"
    copied=$((copied + 1))
  done
  shopt -u nullglob

  if [[ "$copied" -eq 0 ]]; then
    echo "[pgo] no .pgd files found in $collect_dir" >&2
    return 1
  fi

  echo "[pgo] copied $copied .pgd files to $use_dir" >&2
}

run_gather_stage() {
  # Use the shared gather stage for all hosts to keep behavior consistent.
  # The stage itself supports custom commands via
  # KANO_CPP_INFRA_PGO_GATHER_COMMAND / KOG_PGO_GATHER_COMMAND.
  bash "$PGO_GATHER_SH"
}

run_pgo_test_stage() {
  local preset="${KANO_CPP_INFRA_PGO_TEST_PRESET:-$(default_use_build_preset)}"
  local lane="${KANO_TEST_LANE:-quick}"

  export KANO_CPP_INFRA_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_ROOT="$CPP_ROOT"
  export KANO_SKIP_TEST_BUILD="${KANO_SKIP_TEST_BUILD:-1}"
  bash "$STAGES_ROOT/test-lane.sh" "$lane" "$preset"
}

resolve_profile_manifest() {
  local mode="${KANO_CXX_PROFILE_RUN_MODE:-pgo-rebuild}"
  local compiler="${KANO_CXX_COMPILER:-}"
  local coverage_provider="${KANO_CXX_COVERAGE_PROVIDER:-${KANO_CPP_INFRA_COVERAGE_TOOL:-none}}"
  local pgo_provider="${KANO_CXX_PGO_PROVIDER:-}"

  if [[ -z "$compiler" ]]; then
    if is_windows_host; then
      compiler="msvc"
    else
      compiler="clang"
    fi
  fi

  if [[ -z "$pgo_provider" ]]; then
    if [[ "$compiler" == "msvc" ]]; then
      pgo_provider="msvc-pgo"
    elif [[ "$compiler" == "clang" ]]; then
      pgo_provider="llvm-profdata"
    else
      pgo_provider="none"
    fi
  fi

  export KANO_CXX_PROFILE_RUN_MODE="$mode"
  export KANO_CXX_COMPILER="$compiler"
  export KANO_CXX_COVERAGE_PROVIDER="$coverage_provider"
  export KANO_CXX_PGO_PROVIDER="$pgo_provider"

  bash "$PROFILE_MANIFEST_SH" "$mode"
}

archive_microsoft_coverage_reports() {
  local src="$CPP_ROOT/.kano/tmp/pgo/gather-reports"
  local dst="$CPP_ROOT/.kano/tmp/pgo/gather-reports-microsoft"
  if [[ ! -d "$src" ]]; then
    return 0
  fi
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
  echo "[pgo] archived Microsoft coverage reports: $dst" >&2
}

run_microsoft_coverage_prepass() {
  local configure_preset="${KANO_CPP_INFRA_COVERAGE_CONFIGURE_PRESET:-$(default_coverage_configure_preset)}"
  local build_preset="${KANO_CPP_INFRA_COVERAGE_BUILD_PRESET:-$(default_coverage_build_preset)}"
  local original_cache_args="${KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON:-}"
  local original_gather_mode="${KANO_CPP_INFRA_PGO_GATHER_MODE:-}"
  local original_collect_preset="${KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET:-}"
  local original_coverage_tool="${KANO_CPP_INFRA_COVERAGE_TOOL:-}"

  echo "[pgo] Microsoft coverage prepass: preset=$configure_preset" >&2

  export KANO_CPP_INFRA_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_ROOT="$CPP_ROOT"
  export KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON="$original_cache_args"

  if is_windows_host; then
    # shellcheck disable=SC1090
    source "$WINDOWS_PRESET_BUILD_SH"
    kano_windows_run_preset "$configure_preset" "$build_preset" "${KANO_CPP_INFRA_VCVARS_ARCH:-x64}"
  else
    # shellcheck disable=SC1090
    source "$UNIX_PRESET_BUILD_SH"
    kano_cpp_run_unix_preset "$configure_preset" "$build_preset"
  fi

  export KANO_CPP_INFRA_PGO_GATHER_MODE="coverage"
  export KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET="$configure_preset"
  export KANO_CPP_INFRA_COVERAGE_TOOL="microsoft"
  run_gather_stage
  archive_microsoft_coverage_reports

  if [[ -n "$original_gather_mode" ]]; then
    export KANO_CPP_INFRA_PGO_GATHER_MODE="$original_gather_mode"
  else
    unset KANO_CPP_INFRA_PGO_GATHER_MODE || true
  fi

  if [[ -n "$original_collect_preset" ]]; then
    export KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET="$original_collect_preset"
  else
    unset KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET || true
  fi

  if [[ -n "$original_coverage_tool" ]]; then
    export KANO_CPP_INFRA_COVERAGE_TOOL="$original_coverage_tool"
  else
    unset KANO_CPP_INFRA_COVERAGE_TOOL || true
  fi
}

main() {
  local stage="${1:-all}"
  case "$stage" in
    all|pgi-build|profile-gather|pgo-build|pgo-test)
      shift || true
      ;;
    *)
      stage="all"
      ;;
  esac

  require_file "$BUILD_METADATA_SH"
  require_file "$UNIX_PRESET_BUILD_SH"
  require_file "$WINDOWS_PRESET_BUILD_SH"
  require_file "$PGO_GATHER_SH"
  require_file "$PGO_WORKFLOW_SH"
  require_file "$PROFILE_MANIFEST_SH"
  require_file "$STAGES_ROOT/test-lane.sh"

  resolve_profile_manifest

  if [[ "$stage" == "profile-gather" ]]; then
    prepare_pgo_collect_environment
    run_gather_stage
    return 0
  fi

  if [[ "$stage" == "pgo-build" ]]; then
    prepare_pgo_collect_environment
    bash "$PGO_WORKFLOW_SH" merge
    copy_msvc_pgd_to_use_dir
    run_use_build
    return 0
  fi

  if [[ "$stage" == "pgo-test" ]]; then
    run_pgo_test_stage
    return 0
  fi

  if is_windows_host && [[ "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" == "microsoft" ]]; then
    echo "[pgo] split pipeline enabled: Microsoft coverage prepass + PGO collect/use" >&2
    run_microsoft_coverage_prepass
    # PGO gather should focus on profile data generation in split mode.
    export KANO_CPP_INFRA_COVERAGE_TOOL="none"
  fi

  run_collect_build

  if [[ "$stage" == "pgi-build" ]]; then
    return 0
  fi

  run_gather_stage

  if [[ "${KANO_CPP_INFRA_PGO_REBUILD_SKIP_USE:-0}" == "1" ]]; then
    echo "[pgo] gather-only mode enabled; skipping merge/use rebuild stage" >&2
    return 0
  fi

  bash "$PGO_WORKFLOW_SH" merge
  copy_msvc_pgd_to_use_dir
  run_use_build
}

main "$@"
