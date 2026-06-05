#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/matrix.sh"

report_script="$(kano_cpp_infra_matrix_default_test_report_script)"

# ─── Resolve layout ────────────────────────────────────────────────────────────
# stages/test-report.sh   → infra/scripts/stages/test-report.sh
# parent: infra/scripts/ → infra/ → src/cpp/ → src/ → workspace root
INFRA_SCRIPTS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
INFRA_BASE_DIR="$(cd -- "$INFRA_SCRIPTS_DIR/.." && pwd)"
CPP_ROOT="$(cd -- "$INFRA_BASE_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$CPP_ROOT/../.." && pwd)"

export KANO_CPP_INFRA_CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-${CPP_ROOT}}"
export KANO_CPP_INFRA_REPO_ROOT="${KANO_CPP_INFRA_REPO_ROOT:-${REPO_ROOT}}"

# ─── Detect preset from build output layout ─────────────────────────────────────
detect_preset_from_bin_dir() {
    local cpp_root="$1"
    local fallback=""
    for bin_subdir in "$cpp_root/out/bin/"*; do
        [[ -d "$bin_subdir" ]] || continue
        local preset_name
        preset_name="$(basename "$bin_subdir")"
        if [[ -d "$bin_subdir/debug" || -d "$bin_subdir/release" || -d "$bin_subdir/relwithdebinfo" ]]; then
            [[ -z "$fallback" ]] && fallback="$preset_name"
            if [[ -f "$bin_subdir/debug/kano_git_cli_tests.exe" || -f "$bin_subdir/release/kano_git_cli_tests.exe" || -f "$bin_subdir/relwithdebinfo/kano_git_cli_tests.exe" || -f "$bin_subdir/minsizerel/kano_git_cli_tests.exe" || -f "$bin_subdir/debug/kano_git_cli_tests" || -f "$bin_subdir/release/kano_git_cli_tests" || -f "$bin_subdir/relwithdebinfo/kano_git_cli_tests" || -f "$bin_subdir/minsizerel/kano_git_cli_tests" ]]; then
                printf '%s\n' "$preset_name"
                return 0
            fi
        fi
    done
    if [[ -n "$fallback" ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi
    return 1
}

DETECTED_PRESET="${KANO_TEST_PRESET:-$(kano_cpp_infra_matrix_default_release_configure_preset || true)}"
if [[ -z "$DETECTED_PRESET" ]]; then
    DETECTED_PRESET="$(detect_preset_from_bin_dir "$CPP_ROOT" || true)"
fi
if [[ -z "$DETECTED_PRESET" ]]; then
    echo "[ERROR] Could not detect preset from $CPP_ROOT/out/bin/" >&2
    echo "[ERROR] No built binaries found. Run 'pixi run --manifest-path src/cpp/shared/infra/pixi.toml build' first." >&2
    exit 1
fi

# ─── Use the same lane-aware runner contract as `pixi run test` ────────────────
REPORT_LANE="${KANO_TEST_LANE:-default}"
case "$REPORT_LANE" in
    default|test)
        REPORT_LANE="default"
        ;;
    quick|full)
        ;;
    *)
        echo "[ERROR] Unsupported test-report lane: $REPORT_LANE" >&2
        exit 2
        ;;
esac

export KANO_REPORT_ROOT="${KANO_REPORT_ROOT:-$CPP_ROOT/.kano/tmp/pgo/test-reports}"
export KANO_REPORT_SLUG="${KANO_REPORT_SLUG:-test}"
export KANO_TEST_LANE="$REPORT_LANE"
export KANO_REPORT_COMMAND="${KANO_REPORT_COMMAND:-pixi run gather-reports}"
export KANO_TEST_SUITE_MAP_REL="${KANO_TEST_SUITE_MAP_REL:-raw/suite-map.kano-git-master.json}"
export KANO_TEST_REPORTS_ROOT="${KANO_TEST_REPORTS_ROOT:-$KANO_REPORT_ROOT/test-reports}"
export KANO_COVERAGE_REPORTS_ROOT="${KANO_COVERAGE_REPORTS_ROOT:-$KANO_REPORT_ROOT/coverage-reports}"
export KANO_TEST_XML="${KANO_TEST_XML:-$KANO_TEST_REPORTS_ROOT/$KANO_REPORT_SLUG/tests.xml}"
export KANO_BDD_METADATA_DIR="${KANO_BDD_METADATA_DIR:-$KANO_REPORT_ROOT/raw/bdd-metadata}"
export KANO_TEST_COMMAND="${KANO_TEST_COMMAND:-bash \"$CPP_ROOT/code/tests/run_tests.sh\" \"$DETECTED_PRESET\" \"$REPORT_LANE\"}"

mkdir -p "$KANO_REPORT_ROOT/raw" "$KANO_BDD_METADATA_DIR"
cp -f "$INFRA_BASE_DIR/config/suite-map.kano-git-master.json" "$KANO_REPORT_ROOT/raw/suite-map.kano-git-master.json"

exec bash "$report_script" "$@"
