#!/usr/bin/env bash

set -euo pipefail

KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/report_skill_adapter.sh"
. "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/../lib/native_tool.sh"

run_test_report() {
  : "${KANO_REPORT_SLUG:?KANO_REPORT_SLUG is required}"
  : "${KANO_TEST_COMMAND:?KANO_TEST_COMMAND is required}"

  report_skill_load
  export KANO_CPP_TEST_SKILL_ROOT="${KANO_CPP_TEST_SKILL_ROOT:?}"
  local report_title="${KANO_REPORT_TITLE:-${KANO_REPORT_SLUG}}"

  # shellcheck disable=SC1090
  . "$KANO_CPP_TEST_SKILL_ROOT/src/shell/reports/common/report-env.sh"

  rm -f "$KANO_TEST_XML"
  mkdir -p "$KANO_TEST_REPORT_DIR"

  (
    cd "$KANO_CPP_INFRA_CPP_ROOT"
    eval "$KANO_TEST_COMMAND"
  )

  kano_cpp_infra_tool render-junit-report "$KANO_TEST_XML" "$KANO_TEST_REPORT_DIR" "$report_title"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_test_report "$@"
fi
