#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPT="src/cpp/shared/infra/scripts/platform/linux/ci-coverage-all.sh"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/linux_ci_runner.sh"

if ! kano_cpp_linux_ci_is_linux_host; then
  kano_cpp_linux_ci_exec_via_docker "$REPO_SCRIPT" "$@"
  exit $?
fi

gather_reports_root="$KANO_CPP_LINUX_CI_CPP_ROOT/.kano/tmp/pgo/gather-reports"

kano_cpp_linux_ci_run_coverage_build
rm -rf -- "$gather_reports_root"
kano_cpp_linux_ci_run_coverage_gather
kano_cpp_linux_ci_canonicalize_gather_reports "$gather_reports_root"
