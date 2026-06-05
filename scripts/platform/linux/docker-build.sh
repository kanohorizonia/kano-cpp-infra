#!/usr/bin/env bash
# =============================================================================
# Linux Docker Build Helper — kano-cpp-infra
# =============================================================================
# Runs a Linux preset build inside a Docker container.
# Consumer sets KANO_CPP_ROOT / INF_CPP_ROOT / KOB_CPP_ROOT before calling.
# =============================================================================
set -euo pipefail

KANO_INFRA_LINUX_DOCKER_BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${KANO_INFRA_LINUX_DOCKER_BUILD_DIR}/../../lib/docker_linux_build.sh"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  kano_cpp_run_linux_preset_via_docker "$@"
fi
