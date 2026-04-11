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

# ─── Infer KANO_CPP_INFRA_CPP_ROOT ─────────────────────────────────────────────
# Required by lib/report_skill_adapter.sh → report_skill_load()
export KANO_CPP_INFRA_CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-${CPP_ROOT}}"
export KANO_CPP_INFRA_REPO_ROOT="${KANO_CPP_INFRA_REPO_ROOT:-${REPO_ROOT}}"

# ─── Detect preset from build output layout ─────────────────────────────────────
# Binary dir pattern: out/bin/<preset>/<config>/
# Resolve the preset from whichever bin directory actually exists.
detect_preset_from_bin_dir() {
    local cpp_root="$1"
    local bin_subdir

    for bin_subdir in "$cpp_root/out/bin/"*; do
        [[ -d "$bin_subdir" ]] || continue
        local preset_name
        preset_name="$(basename "$bin_subdir")"
        if [[ -d "$bin_subdir/debug" || -d "$bin_subdir/release" || -d "$bin_subdir/relwithdebinfo" ]]; then
            printf '%s\n' "$preset_name"
            return 0
        fi
    done
    return 1
}

DETECTED_PRESET="$(detect_preset_from_bin_dir "$CPP_ROOT" || true)"
if [[ -z "$DETECTED_PRESET" ]]; then
    echo "[ERROR] Could not detect preset from $CPP_ROOT/out/bin/" >&2
    echo "[ERROR] No built binaries found. Run 'pixi run build' first." >&2
    exit 1
fi

# ─── Infer KANO_REPORT_SLUG ────────────────────────────────────────────────────
# Default to <preset>-release; caller can still override via env.
export KANO_REPORT_SLUG="${KANO_REPORT_SLUG:-${DETECTED_PRESET}-release}"

# ─── Locate test binaries ───────────────────────────────────────────────────────
EXE_DIR="$CPP_ROOT/out/bin/${DETECTED_PRESET}/release"

if [[ ! -d "$EXE_DIR" ]]; then
    echo "[ERROR] Test binary directory not found: $EXE_DIR" >&2
    echo "[ERROR] Run 'pixi run build' first." >&2
    exit 1
fi

CLI_TEST="$EXE_DIR/kano_git_cli_tests.exe"
TUI_TEST="$EXE_DIR/kano_git_tui_tests.exe"

if [[ ! -f "$CLI_TEST" ]]; then
    echo "[ERROR] CLI test binary not found: $CLI_TEST" >&2
    exit 1
fi
if [[ ! -f "$TUI_TEST" ]]; then
    echo "[ERROR] TUI test binary not found: $TUI_TEST" >&2
    exit 1
fi

# ─── Infer KANO_TEST_COMMAND ────────────────────────────────────────────────────
# Runs both test binaries sequentially; captures exit code.
export KANO_TEST_COMMAND="${KANO_TEST_COMMAND:-"$CLI_TEST && $TUI_TEST"}"

exec bash "$report_script" "$@"
