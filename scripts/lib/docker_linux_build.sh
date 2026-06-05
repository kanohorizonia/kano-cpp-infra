#!/usr/bin/env bash
set -euo pipefail

KANO_CPP_DOCKER_LINUX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$KANO_CPP_DOCKER_LINUX_SCRIPT_DIR/docker_host.sh"

kano_cpp_linux_docker_default_cpp_root() {
  cd "$KANO_CPP_DOCKER_LINUX_SCRIPT_DIR/../../../.." >/dev/null 2>&1 && pwd -P
}

kano_cpp_linux_docker_resolve_cpp_root() {
  local cpp_root="${KANO_CPP_ROOT:-${INF_CPP_ROOT:-${KOB_CPP_ROOT:-}}}"
  if [[ -n "$cpp_root" ]]; then
    cd "$cpp_root" >/dev/null 2>&1 && pwd -P
    return 0
  fi
  kano_cpp_linux_docker_default_cpp_root
}

kano_cpp_run_linux_preset_via_docker() {
  local in_configure_preset="${1:-}"
  local in_build_preset="${2:-}"
  local cpp_root=""
  local repo_root=""
  local mount_arg=""
  local docker_image="${KANO_CPP_LINUX_DOCKER_IMAGE:-ubuntu:25.10}"
  local q_configure=""
  local q_build=""
  local container_script=""

  if [[ -z "$in_configure_preset" || -z "$in_build_preset" ]]; then
    echo "Usage: kano_cpp_run_linux_preset_via_docker <configure-preset> <build-preset>" >&2
    return 1
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required." >&2
    return 1
  fi

  cpp_root="$(kano_cpp_linux_docker_resolve_cpp_root)" || {
    echo "Unable to resolve C++ root for Linux Docker build." >&2
    return 1
  }
  repo_root="$(cd "$cpp_root/../.." >/dev/null 2>&1 && pwd -P)"
  mount_arg="$(kano_cpp_docker_volume_arg "$repo_root" /work)" || return 1

  printf -v q_configure '%q' "$in_configure_preset"
  printf -v q_build '%q' "$in_build_preset"
  printf -v container_script '%s\n' \
    "set -euo pipefail" \
    "apt-get update" \
    "DEBIAN_FRONTEND=noninteractive apt-get install -y cmake ninja-build gcc-15 g++-15 clang lld git" \
    "rm -rf /work/src/cpp/out/obj/${q_configure}" \
    "cd /work/src/cpp" \
    "cmake --preset ${q_configure}" \
    "cmake --build --preset ${q_build}"

  # --security-opt seccomp=unconfined: required for sanitizer builds (TSan uses
  # personality(ADDR_NO_RANDOMIZE) which the default Docker seccomp profile blocks)
  kano_cpp_docker_run run --rm \
    --security-opt seccomp=unconfined \
    -v "$mount_arg" \
    -w /work/src/cpp \
    "$docker_image" \
    bash -lc "$container_script"
}

inf_run_linux_preset_via_docker() {
  kano_cpp_run_linux_preset_via_docker "$@"
}
