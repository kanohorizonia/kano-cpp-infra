#!/usr/bin/env bash

set -euo pipefail

KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/report_skill_adapter.sh"

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

  if [[ -f "$KANO_TEST_XML" ]]; then
    python "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/../tools/generate-bdd-metadata-from-junit.py" \
      "$KANO_TEST_XML" \
      "${KANO_BDD_METADATA_DIR:-$KANO_REPORT_ROOT/raw/bdd-metadata}" \
      "${KANO_TEST_BINARY_NAME:-kano_git_cli_tests}"
  else
    echo "[WARN] KANO_TEST_XML was not written by test command: $KANO_TEST_XML" >&2
  fi

  python "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/render_junit_test_report.py" "$KANO_TEST_XML" "$KANO_TEST_REPORT_DIR" "$report_title"
  bash "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/package-reports-with-skill.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_test_report "$@"
fi
