#!/usr/bin/env bash
# =============================================================================
# Linux Docker Build Helper — kano-cpp-infra
# =============================================================================
# Runs a Linux preset build inside a Docker container.
# Consumer sets KANO_CPP_ROOT / KOG_CPP_ROOT / KOB_CPP_ROOT before calling.
# =============================================================================
set -euo pipefail

# Resolve infra scripts root
_INFRA_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common build metadata (infra version — always available via submodule)
if [[ -f "${_INFRA_SCRIPTS_DIR}/../common/build_metadata.sh" ]]; then
  # shellcheck disable=SC1091
  source "${_INFRA_SCRIPTS_DIR}/../common/build_metadata.sh"
fi

# =============================================================================
# kano_cpp_run_linux_preset_via_docker
# =============================================================================
# Args:
#   $1  configure preset name  (e.g. linux-ninja-clang)
#   $2  build preset name      (e.g. linux-ninja-clang-debug)
# =============================================================================
kano_cpp_run_linux_preset_via_docker() {
  local in_configure_preset="${1:-}"
  local in_build_preset="${2:-}"

  if [[ -z "$in_configure_preset" || -z "$in_build_preset" ]]; then
    echo "Usage: kano_cpp_run_linux_preset_via_docker <configure-preset> <build-preset>" >&2
    return 1
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required." >&2
    exit 1
  fi

  if ! command -v powershell >/dev/null 2>&1; then
    echo "powershell is required." >&2
    exit 1
  fi

  local cpp_root
  cpp_root="$(kano_cpp_root)"

  local repo_root_win
  repo_root_win="$(cd "${cpp_root}/../.." && pwd -W)"
  repo_root_win="${repo_root_win//\'/\'\'}"

  # --security_opt seccomp=unconfined: required for sanitizer builds (TSan uses
  # personality(ADDR_NO_RANDOMIZE) which the default Docker seccomp profile blocks)
  powershell -NoProfile -ExecutionPolicy Bypass -Command "& { docker run --rm --security-opt seccomp=unconfined -v '$repo_root_win:/work' -w /work/src/cpp ubuntu:25.10 bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y     cmake ninja-build gcc-15 g++-15 clang lld git && rm -rf /work/src/cpp/out/obj/$in_configure_preset && cmake --preset $in_configure_preset && cmake --build --preset $in_build_preset'; exit \$LASTEXITCODE }"
}
