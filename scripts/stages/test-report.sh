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

DETECTED_PRESET="$(detect_preset_from_bin_dir "$CPP_ROOT" || true)"
if [[ -z "$DETECTED_PRESET" ]]; then
    echo "[ERROR] Could not detect preset from $CPP_ROOT/out/bin/" >&2
    echo "[ERROR] No built binaries found. Run 'pixi run --manifest-path src/cpp/shared/infra/pixi.toml build' first." >&2
    exit 1
fi

# ─── Locate config subdir (debug/release/relwithdebinfo) with test binaries ────
resolve_config_dir() {
    local preset_bin_dir="$1"
    for config_dir in "$preset_bin_dir"/debug "$preset_bin_dir"/release \
                     "$preset_bin_dir"/relwithdebinfo "$preset_bin_dir"/minsizerel; do
        if [[ -f "$config_dir/kano_git_cli_tests.exe" || -f "$config_dir/kano_git_cli_tests" ]]; then
            printf '%s\n' "$config_dir"
            return 0
        fi
    done
    return 1
}

PRESET_BIN_DIR="$CPP_ROOT/out/bin/${DETECTED_PRESET}"
EXE_DIR="$(resolve_config_dir "$PRESET_BIN_DIR")"

if [[ -z "$EXE_DIR" ]]; then
    echo "[ERROR] No test binaries found under $PRESET_BIN_DIR/{debug,release,relwithdebinfo}" >&2
    echo "[ERROR] Run 'pixi run --manifest-path src/cpp/shared/infra/pixi.toml build' first." >&2
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

# ─── Derive KANO_REPORT_SLUG from actual config subdir ─────────────────────────
CONFIG_SUBDIR="$(basename "$EXE_DIR")"
export KANO_REPORT_SLUG="${KANO_REPORT_SLUG:-${DETECTED_PRESET}-${CONFIG_SUBDIR}}"

# ─── Infer KANO_TEST_COMMAND ────────────────────────────────────────────────────
export KANO_TEST_COMMAND="${KANO_TEST_COMMAND:-"$CLI_TEST && $TUI_TEST"}"

exec bash "$report_script" "$@"
