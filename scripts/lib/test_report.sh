#!/usr/bin/env bash

set -euo pipefail

KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/report_skill_adapter.sh"
. "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/python_resolver.sh"

kano_cpp_infra_report_resolve_path_fallback() {
  local raw_path="${1:-}"
  local base_dir="${2:-$(pwd -P)}"
  local normalized

  if [[ -z "$raw_path" ]]; then
    return 0
  fi

  normalized="${raw_path//\\//}"
  if command -v cygpath >/dev/null 2>&1 && [[ "$normalized" =~ ^[A-Za-z]:/ ]]; then
    cygpath -u "$normalized"
    return 0
  fi
  if [[ "$normalized" == /* ]]; then
    printf '%s\n' "$normalized"
    return 0
  fi
  if [[ "$normalized" == "." ]]; then
    printf '%s\n' "$base_dir"
    return 0
  fi

  normalized="${normalized#./}"
  printf '%s/%s\n' "${base_dir%/}" "$normalized"
}

run_test_report() {
  : "${KANO_REPORT_SLUG:?KANO_REPORT_SLUG is required}"
  : "${KANO_TEST_COMMAND:?KANO_TEST_COMMAND is required}"

  report_skill_load
  export KANO_CPP_TEST_SKILL_ROOT="${KANO_CPP_TEST_SKILL_ROOT:?}"
  local report_title="${KANO_REPORT_TITLE:-${KANO_REPORT_SLUG}}"
  local python_bin
  python_bin="$(kano_resolve_python_bin)"

  # shellcheck disable=SC1090
  . "$KANO_CPP_TEST_SKILL_ROOT/src/shell/reports/common/report-env.sh"
  # Keep report generation working when agents still have an older
  # kano-cpp-test-skill checkout that does not export kct_report_resolve_path.
  if ! declare -F kct_report_resolve_path >/dev/null 2>&1; then
    echo "[WARN] report-env.sh did not export kct_report_resolve_path; using shared infra fallback." >&2
    kct_report_resolve_path() {
      kano_cpp_infra_report_resolve_path_fallback "$@"
    }
  fi
  export KANO_BDD_METADATA_DIR="$(kct_report_resolve_path "${KANO_BDD_METADATA_DIR:-$KANO_REPORT_ROOT/raw/bdd-metadata}")"

  rm -f "$KANO_TEST_XML"
  mkdir -p "$KANO_TEST_REPORT_DIR"
  mkdir -p "$KANO_BDD_METADATA_DIR"

  (
    cd "$KANO_CPP_INFRA_CPP_ROOT"
    eval "$KANO_TEST_COMMAND"
  )

if [[ -f "$KANO_TEST_XML" ]]; then
    kano_python "$python_bin" "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/../tools/generate-bdd-metadata-from-junit.py" \
      "$KANO_TEST_XML" \
      "$KANO_BDD_METADATA_DIR" \
      "${KANO_TEST_BINARY_NAME:-kano_git_cli_tests}"
else
    echo "[WARN] KANO_TEST_XML was not written by test command: $KANO_TEST_XML" >&2
    mkdir -p "$(dirname "$KANO_TEST_XML")"
    cat <<'EOF' > "$KANO_TEST_XML"
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="kano-git-master-skill.test-report.missing" tests="0" failures="0" errors="0" skipped="0" time="0" />
</testsuites>
EOF
fi

  kano_python "$python_bin" "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/render_junit_test_report.py" "$KANO_TEST_XML" "$KANO_TEST_REPORT_DIR" "$report_title"
  bash "$KANO_CPP_INFRA_TEST_REPORT_SCRIPT_DIR/package-reports-with-skill.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_test_report "$@"
fi
