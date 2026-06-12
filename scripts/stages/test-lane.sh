#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_SCRIPTS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
INFRA_BASE_DIR="$(cd -- "$INFRA_SCRIPTS_DIR/.." && pwd)"
CPP_ROOT="$(cd -- "$INFRA_BASE_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$CPP_ROOT/../.." && pwd)"
. "$INFRA_BASE_DIR/scripts/lib/native_tool.sh"

LANE="${1:-default}"
PRESET="${2:-windows-ninja-msvc-release}"
CONFIG="${KANO_TEST_CONFIG:-Release}"
RUNNER_PRESET="$PRESET"

case "$RUNNER_PRESET" in
  *-debug)
    RUNNER_PRESET="${RUNNER_PRESET%-debug}"
    CONFIG="${KANO_TEST_CONFIG:-Debug}"
    ;;
  *-release)
    RUNNER_PRESET="${RUNNER_PRESET%-release}"
    CONFIG="${KANO_TEST_CONFIG:-Release}"
    ;;
  *-relwithdebinfo)
    RUNNER_PRESET="${RUNNER_PRESET%-relwithdebinfo}"
    CONFIG="${KANO_TEST_CONFIG:-RelWithDebInfo}"
    ;;
  *-minsizerel)
    RUNNER_PRESET="${RUNNER_PRESET%-minsizerel}"
    CONFIG="${KANO_TEST_CONFIG:-MinSizeRel}"
    ;;
esac

case "$LANE" in
  quick)
    REPORT_ROOT="$CPP_ROOT/.kano/tmp/pgo/quick-test-reports"
    REPORT_SLUG="quick"
    TEST_CMD="pixi run quick-test"
    ;;
  default|test)
    REPORT_ROOT="$CPP_ROOT/.kano/tmp/pgo/test-reports"
    REPORT_SLUG="test"
    TEST_CMD="pixi run test"
    LANE="default"
    ;;
  full)
    REPORT_ROOT="$CPP_ROOT/.kano/tmp/pgo/full-test-reports"
    REPORT_SLUG="full"
    TEST_CMD="pixi run full-test"
    ;;
  *)
    echo "Unknown lane: $LANE" >&2
    exit 2
    ;;
esac

export KANO_CPP_INFRA_REPO_ROOT="$REPO_ROOT"
export KANO_CPP_INFRA_CPP_ROOT="$CPP_ROOT"
export KANO_REPORT_ROOT="$REPORT_ROOT"
export KANO_REPORT_SLUG="$REPORT_SLUG"
export KANO_TEST_LANE="$LANE"
export KANO_TEST_COMMAND="$TEST_CMD"
export KANO_REPORT_COMMAND="pixi run gather-reports"
export KANO_TEST_SUITE_MAP_REL="raw/suite-map.kano-git-master.json"
export KANO_TEST_REPORTS_ROOT="$REPORT_ROOT/test-reports"
export KANO_COVERAGE_REPORTS_ROOT="$REPORT_ROOT/coverage-reports"
export KANO_TEST_XML="$REPORT_ROOT/test-reports/$REPORT_SLUG/tests.xml"
export KANO_BDD_METADATA_DIR="${KANO_BDD_METADATA_DIR:-$REPORT_ROOT/raw/bdd-metadata}"

mkdir -p "$REPORT_ROOT/raw"
rm -rf -- "$KANO_BDD_METADATA_DIR"
mkdir -p "$KANO_BDD_METADATA_DIR"
cp -f "$INFRA_BASE_DIR/config/suite-map.kano-git-master.json" "$REPORT_ROOT/raw/suite-map.kano-git-master.json"

bash "$CPP_ROOT/code/tests/run_tests.sh" "$RUNNER_PRESET" "$CONFIG" "$LANE"
if [[ -f "$KANO_TEST_XML" ]]; then
  kano_cpp_infra_tool generate-bdd-metadata \
    "$KANO_TEST_XML" \
    "$KANO_BDD_METADATA_DIR" \
    "kano_git_cli_tests"
fi
bash "$INFRA_BASE_DIR/scripts/lib/package-reports-with-skill.sh"
