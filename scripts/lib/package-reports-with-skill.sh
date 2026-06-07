#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/report_skill_adapter.sh"
. "$SCRIPT_DIR/python_resolver.sh"

render_fallback_report() {
  local report_root="${KANO_REPORT_ROOT:-${KANO_CPP_INFRA_REPORT_ROOT:-.kano/tmp/reports}}"
  local title="${KANO_REPORT_TITLE:-${KANO_REPORT_SLUG:-Test Report}}"
  local test_xml="${KANO_TEST_XML:-}"
  local python_bin

  mkdir -p "$report_root"

  if [[ -n "$test_xml" && -f "$test_xml" ]]; then
    python_bin="$(kano_resolve_python_bin)"
    kano_python "$python_bin" "$SCRIPT_DIR/render_junit_test_report.py" "$test_xml" "$report_root" "$title"
    echo "[WARN] kano-cpp-test-skill unavailable; rendered fallback JUnit report: $report_root/index.html" >&2
    return 0
  fi

  cat > "$report_root/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Kano Test Report</title>
</head>
<body>
  <h1>Kano Test Report</h1>
  <p>kano-cpp-test-skill was not available and no JUnit XML was found for fallback rendering.</p>
</body>
</html>
EOF
  echo "[WARN] kano-cpp-test-skill unavailable; wrote fallback status report: $report_root/index.html" >&2
}

if report_skill_load; then
  report_skill_package "$@"
else
  render_fallback_report
fi
