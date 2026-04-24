#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap pixi environment if not already active
source "$SCRIPT_DIR/pixi_bootstrap.sh"
kano_pixi_bootstrap_activate

# Accept KANO_CPP_ROOT as fallback for INF_CPP_ROOT (pixi_bootstrap sets this)
INF_CPP_ROOT="${INF_CPP_ROOT:-${KANO_CPP_ROOT:-}}"
if [[ -z "${INF_CPP_ROOT:-}" ]]; then
  echo "INF_CPP_ROOT is not set." >&2
  exit 1
fi

source "$SCRIPT_DIR/build_metadata.sh"

# =============================================================================
# inf_run_unix_preset — git-master wrapper around kano_cpp_run_unix_preset
# =============================================================================
# Applies git-master-specific overrides (LLVM prefix, modules) then delegates.
# =============================================================================
inf_run_unix_preset() {
  local in_configure_preset="$1"
  local in_build_preset="$2"
  local -a extra_args=()
  local -a cache_override_args=()
  local llvm_prefix=""
  local sdk_path=""
  local arch=""
  local preset_name=""

  if [[ -n "${INF_CMAKE_CACHE_ARGS_JSON:-}" ]]; then
    cache_override_args+=("$(python - <<'PY'
import json, os
data = json.loads(os.environ['INF_CMAKE_CACHE_ARGS_JSON'])
for key, value in data.items():
    print(f'-D{key}={value}')
PY
)")
  fi

  if [[ "${INF_BUILD_ENABLE_MODULES:-0}" == "1" ]]; then
    extra_args+=("-DINF_ENABLE_MODULES=ON")
  else
    extra_args+=("-DINF_ENABLE_MODULES=OFF")
  fi

  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" && "${INF_BUILD_USE_LLVM:-0}" == "1" ]]; then
    llvm_prefix="$(brew --prefix llvm 2>/dev/null || true)"
    if [[ -z "$llvm_prefix" || ! -x "$llvm_prefix/bin/clang" || ! -x "$llvm_prefix/bin/clang++" ]]; then
      echo "Homebrew LLVM is required for --llvm mode. Install with: brew install llvm" >&2
      return 1
    fi

    sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"

    arch="$(uname -m 2>/dev/null || true)"
    if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
      preset_name="macos-ninja-llvm-arm64"
    else
      preset_name="macos-ninja-llvm-x64"
    fi

    extra_args+=(
      "-DCMAKE_C_COMPILER=$llvm_prefix/bin/clang"
      "-DCMAKE_CXX_COMPILER=$llvm_prefix/bin/clang++"
      "-DINF_PRESET_NAME=$preset_name"
    )
    if [[ -n "$sdk_path" ]]; then
      extra_args+=("-DCMAKE_OSX_SYSROOT=$sdk_path")
    fi
  fi

  (
    cd "$INF_CPP_ROOT"
    inf_apply_self_build_config
    inf_collect_build_metadata
    # shellcheck disable=SC2206
    local _cache_args=( ${cache_override_args[*]:-} )
    cmake --preset "$in_configure_preset" "${extra_args[@]}" "${_cache_args[@]}"
    cmake --build --preset "$in_build_preset"
  )
}
