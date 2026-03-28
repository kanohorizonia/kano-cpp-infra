#!/usr/bin/env bash
# =============================================================================
# Generic Unix Preset Build Helper — kano-cpp-infra
# =============================================================================
# Provides kano_cpp_run_unix_preset() for Linux/macOS cross-host builds.
# Consumers source this and call kano_cpp_run_unix_preset with their prefix.
# =============================================================================
set -euo pipefail

# Resolve infra scripts root (two levels up from this file in the infra submodule)
_INFRA_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_INFRA_COMMON_DIR="$_INFRA_SCRIPTS_DIR"

# Source common build metadata (infra version — always available via submodule)
if [[ -f "${_INFRA_COMMON_DIR}/build_metadata.sh" ]]; then
  # shellcheck disable=SC1091
  source "${_INFRA_COMMON_DIR}/build_metadata.sh"
fi

# =============================================================================
# kano_cpp_run_unix_preset — generic preset launcher
# =============================================================================
# Args:
#   $1  configure preset name  (e.g. linux-ninja-clang)
#   $2  build preset name      (e.g. linux-ninja-clang-debug)
#   $3  optional prefix         (default: KANO — used for *_APPLY_SELF_BUILD_CONFIG
#                                and *_COLLECT_BUILD_METADATA env vars)
# =============================================================================
kano_cpp_run_unix_preset() {
  local in_configure_preset="${1:-}"
  local in_build_preset="${2:-}"
  local prefix="${3:-KANO}"

  if [[ -z "$in_configure_preset" || -z "$in_build_preset" ]]; then
    echo "Usage: kano_cpp_run_unix_preset <configure-preset> <build-preset> [prefix]" >&2
    return 1
  fi

  local cpp_root
  cpp_root="$(kano_cpp_root)"

  # Apply compiler-launcher / compiler-cache config for this consumer
  kano_cpp_apply_self_build_config "$prefix"

  # Collect build metadata (emits PREFIX_BUILD_* env vars)
  kano_cpp_collect_build_metadata "$prefix"

  (
    cd "$cpp_root"
    cmake --preset "$in_configure_preset"
    cmake --build --preset "$in_build_preset"
  )
}
