#!/usr/bin/env bash
set -euo pipefail

KANO_INFRA_UNIX_PRESET_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$KANO_INFRA_UNIX_PRESET_SCRIPT_DIR/native_tool.sh"

# Bootstrap pixi environment if not already active.
# shellcheck source=/dev/null
source "$KANO_INFRA_UNIX_PRESET_SCRIPT_DIR/pixi_bootstrap.sh"
kano_pixi_bootstrap_activate

# Accept KANO_CPP_ROOT as fallback for INF_CPP_ROOT (pixi_bootstrap sets this).
INF_CPP_ROOT="${INF_CPP_ROOT:-${KANO_CPP_ROOT:-}}"
if [[ -z "${INF_CPP_ROOT:-}" ]]; then
  echo "INF_CPP_ROOT is not set." >&2
  exit 1
fi
export INF_CPP_ROOT
export KANO_CPP_ROOT="${KANO_CPP_ROOT:-$INF_CPP_ROOT}"
export KANO_CPP_INFRA_CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$INF_CPP_ROOT}"

# shellcheck source=/dev/null
source "$KANO_INFRA_UNIX_PRESET_SCRIPT_DIR/build_metadata.sh"

# =============================================================================
# kano_cpp_run_unix_preset
# =============================================================================
# Runs a Unix CMake configure/build preset with shared self-build metadata.
# The optional third argument is a log/config prefix kept for API compatibility.
# =============================================================================
kano_cpp_run_unix_preset() {
  local in_configure_preset="${1:-}"
  local in_build_preset="${2:-}"
  local build_prefix="${3:-KANO}"
  local -a extra_args=()
  local -a cache_override_args=()
  local llvm_prefix=""
  local sdk_path=""
  local arch=""
  local preset_name=""

  if [[ -z "$in_configure_preset" || -z "$in_build_preset" ]]; then
    echo "Usage: kano_cpp_run_unix_preset <configure-preset> <build-preset> [prefix]" >&2
    return 1
  fi

  export KANO_CPP_INFRA_BUILD_CONFIGURE_PRESET="$in_configure_preset"
  export KANO_CPP_INFRA_BUILD_BUILD_PRESET="$in_build_preset"
  export KANO_CPP_INFRA_BUILD_PREFIX="$build_prefix"

  if [[ -n "${INF_CMAKE_CACHE_ARGS_JSON:-}" ]]; then
    # shellcheck disable=SC2207
    cache_override_args+=( $(kano_cpp_infra_tool cache-args-to-cmake "$INF_CMAKE_CACHE_ARGS_JSON") )
  fi

  if [[ "${INF_BUILD_ENABLE_MODULES:-${KOG_BUILD_ENABLE_MODULES:-0}}" == "1" ]]; then
    extra_args+=("-DINF_ENABLE_MODULES=ON")
  else
    extra_args+=("-DINF_ENABLE_MODULES=OFF")
  fi

  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" && "${INF_BUILD_USE_LLVM:-${KOG_BUILD_USE_LLVM:-0}}" == "1" ]]; then
    llvm_prefix="$(brew --prefix llvm 2>/dev/null || true)"
    export KANO_CPP_INFRA_LLVM_PREFIX="$llvm_prefix"
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
    kano_cpp_apply_self_build_config
    kano_cpp_collect_build_metadata
    kano_cpp_print_self_build_toolchain
    cmake --preset "$in_configure_preset" "${extra_args[@]}" "${cache_override_args[@]}"
    cmake --build --preset "$in_build_preset"
  )
}

# Backward-compatible alias for older scripts that still call the old infra name.
inf_run_unix_preset() {
  kano_cpp_run_unix_preset "$@"
}

# Backward-compatible aliases for older scripts that still call the old metadata names.
inf_apply_self_build_config() {
  kano_cpp_apply_self_build_config "$@"
}

inf_collect_build_metadata() {
  kano_cpp_collect_build_metadata "$@"
}
