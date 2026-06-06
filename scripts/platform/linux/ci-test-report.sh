#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPT="src/cpp/shared/infra/scripts/platform/linux/ci-test-report.sh"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/linux_ci_runner.sh"

if ! kano_cpp_linux_ci_is_linux_host; then
  kano_cpp_linux_ci_exec_via_docker "$REPO_SCRIPT" "$@"
  exit $?
fi

lane="${KANO_TEST_LANE:-default}"
kano_cpp_linux_ci_prepare_test_report_dirs
kano_cpp_linux_ci_run_test_lane "$(kano_cpp_linux_ci_release_build_preset)" "$lane" "$KANO_TEST_XML"
kano_cpp_linux_ci_generate_bdd_metadata "$KANO_TEST_XML" "$KANO_BDD_METADATA_DIR" "kano_git_cli_tests"
