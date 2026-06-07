#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPT="src/cpp/shared/infra/scripts/platform/linux/ci-pgo-test.sh"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/linux_ci_runner.sh"

export KANO_CPP_INFRA_PGO_USE_CONFIGURE_PRESET="${KANO_CPP_INFRA_PGO_USE_CONFIGURE_PRESET:-linux-ninja-clang-pgo-use}"
export KANO_CPP_INFRA_PGO_USE_BUILD_PRESET="${KANO_CPP_INFRA_PGO_USE_BUILD_PRESET:-linux-ninja-clang-pgo-use-release}"
export KANO_CPP_INFRA_PGO_TEST_PRESET="${KANO_CPP_INFRA_PGO_TEST_PRESET:-linux-ninja-clang-pgo-use-release}"

if ! kano_cpp_linux_ci_is_linux_host; then
  kano_cpp_linux_ci_exec_via_docker "$REPO_SCRIPT" "$@"
  exit $?
fi

export KANO_TEST_LANE="${KANO_TEST_LANE:-quick}"
exec bash "$KANO_CPP_LINUX_CI_INFRA_DIR/scripts/workflows/pgo-rebuild.sh" pgo-test "$@"
