#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPT="src/cpp/shared/infra/scripts/platform/linux/ci-profile-gather.sh"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/linux_ci_runner.sh"

# Linux full profile-gather can spend CI time in property-heavy training tests.
# Keep the CI training lane bounded by default; callers can set this to 0 for
# an explicit full gather run.
export KANO_CPP_INFRA_PGO_GATHER_QUICK="${KANO_CPP_INFRA_PGO_GATHER_QUICK:-1}"

if ! kano_cpp_linux_ci_is_linux_host; then
  kano_cpp_linux_ci_exec_via_docker "$REPO_SCRIPT" "$@"
  exit $?
fi

exec bash "$KANO_CPP_LINUX_CI_INFRA_DIR/scripts/workflows/pgo-rebuild.sh" profile-gather "$@"
