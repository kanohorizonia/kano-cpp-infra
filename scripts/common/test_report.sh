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
  export KANO_CPP_INFRA_REPO_ROOT="${KANO_CPP_INFRA_REPO_ROOT:-$(cd -- "$KANO_CPP_INFRA_CPP_ROOT/../.." && pwd)}"
  local report_title="${KANO_REPORT_TITLE:-${KANO_REPORT_SLUG}}"

  # shellcheck disable=SC1090
  . "$KANO_CPP_TEST_SKILL_ROOT/src/shell/reports/common/report-env.sh"
  export KANO_BDD_METADATA_DIR="${KANO_BDD_METADATA_DIR:-$KANO_REPORT_ROOT/raw/bdd-metadata}"
  export KANO_BDD_FEATURE_MANIFEST="${KANO_BDD_FEATURE_MANIFEST:-$KANO_CPP_INFRA_REPO_ROOT/src/cpp/shared/infra/config/bdd-feature-manifest.kano-agent-backlog-skill.json}"

  rm -f "$KANO_TEST_XML"
  mkdir -p "$KANO_TEST_REPORT_DIR"
  mkdir -p "$KANO_BDD_METADATA_DIR"

  (
    cd "$KANO_CPP_INFRA_CPP_ROOT"
    eval "$KANO_TEST_COMMAND"
  )

  if [[ -f "$KANO_TEST_XML" ]]; then
    kano_cpp_infra_tool generate-bdd-metadata \
      "$KANO_TEST_XML" \
      "$KANO_BDD_METADATA_DIR" \
      "${KANO_TEST_BINARY_NAME:-kano_git_cli_tests}"
  fi

  local -a render_args=("$KANO_TEST_XML" "$KANO_TEST_REPORT_DIR" "$report_title" "$KANO_BDD_METADATA_DIR")
  if [[ -f "$KANO_BDD_FEATURE_MANIFEST" ]]; then
    render_args+=("$KANO_BDD_FEATURE_MANIFEST")
  fi
  kano_cpp_infra_tool render-junit-report "${render_args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_test_report "$@"
fi
