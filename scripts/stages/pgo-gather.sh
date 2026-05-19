#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"

resolve_collect_preset() {
  if [[ -n "${KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET:-}" ]]; then
    printf '%s\n' "$KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET"
    return 0
  fi

  if [[ "$(uname -s 2>/dev/null || true)" == MINGW* || "$(uname -s 2>/dev/null || true)" == MSYS* || "$(uname -s 2>/dev/null || true)" == CYGWIN* ]]; then
    printf '%s\n' "windows-ninja-msvc-pgo-collect"
    return 0
  fi

  printf '%s\n' "linux-ninja-gcc-pgo-collect"
}

is_windows_host() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_windows_pgo_runtime_path() {
  if ! is_windows_host; then
    return 0
  fi

  if command -v where.exe >/dev/null 2>&1 && where.exe pgort140.dll >/dev/null 2>&1; then
    return 0
  fi

  local tool_bin
  shopt -s nullglob
  for tool_bin in /c/Program\ Files/Microsoft\ Visual\ Studio/*/*/VC/Tools/MSVC/*/bin/Hostx64/x64; do
    if [[ -f "$tool_bin/pgort140.dll" ]]; then
      export PATH="$tool_bin:$PATH"
      echo "[pgo-gather] added MSVC PGO runtime path: $tool_bin" >&2
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  echo "[pgo-gather] warning: pgort140.dll not found on PATH; some collect tests may fail to start" >&2
  return 0
}

run_collect_case() {
  local in_candidate="$1"
  local in_label="$2"
  local in_filter="$3"
  local in_reports_dir="$4"
  local in_logs_dir="$5"

  local report_path="$in_reports_dir/$in_label.xml"
  local log_path="$in_logs_dir/$in_label.log"

  local -a args
  local -a reporter_args=(--reporter junit --out "$report_path")
  args=(--order lex --rng-seed 1337 --durations yes)
  if [[ -n "$in_filter" ]]; then
    args+=("$in_filter")
  fi
  args+=("${reporter_args[@]}")

  echo "[pgo-gather] running $in_label (${in_filter:-all-tests})" >&2
  if "$in_candidate" "${args[@]}" >"$log_path" 2>&1; then
    echo "[pgo-gather] pass $in_label" >&2
    return 0
  fi

  echo "[pgo-gather] warning: $in_label failed for filter '${in_filter:-all-tests}', retry full binary" >&2
  if "$in_candidate" --order lex --rng-seed 1337 "${reporter_args[@]}" >"$log_path" 2>&1; then
    echo "[pgo-gather] pass $in_label (fallback all-tests)" >&2
    return 0
  fi

  echo "[pgo-gather] warning: $in_label fallback failed; see $log_path" >&2
  return 1
}

run_collect_tests_default() {
  local preset_name
  local bin_root
  local exe_ext=""
  local test_bin
  local passed_count=0
  local failed_count=0
  local reports_root
  local reports_dir
  local logs_dir
  local suite_entry
  local label
  local filter
  local candidate

  preset_name="$(resolve_collect_preset)"
  bin_root="$CPP_ROOT/out/bin/$preset_name/debug"
  reports_root="$CPP_ROOT/.kano/tmp/pgo/gather-reports"
  reports_dir="$reports_root/junit"
  logs_dir="$reports_root/logs"

  mkdir -p "$reports_dir" "$logs_dir"

  if is_windows_host; then
    exe_ext=".exe"
  fi

  ensure_windows_pgo_runtime_path

  # Coverage-guided representative defaults:
  # - CLI functional path
  # - commit-plan engine + properties
  # - export/archive paths
  # - TUI command-state/autocomplete paths
  local -a suite=(
    "kano_git_cli_tests|[Functional]"
    "kano_git_commit_plan_tests|[Unit],[Property]"
    "kano_git_export_tests|[Unit],[Integration]"
    "kano_git_tui_tests|[Unit],[Property]"
  )

  for suite_entry in "${suite[@]}"; do
    IFS='|' read -r test_bin filter <<< "$suite_entry"
    label="${test_bin}"
    candidate="$bin_root/$test_bin$exe_ext"

    if [[ ! -f "$candidate" ]]; then
      echo "[pgo-gather] missing collect test binary: $candidate" >&2
      exit 1
    fi

    # Catch2 v3 uses --list-tests. Keep a cheap preflight list to confirm binary health.
    if ! "$candidate" --list-tests >"$logs_dir/${label}.list.log" 2>&1; then
      echo "[pgo-gather] warning: $label failed --list-tests preflight; continuing" >&2
    fi

    if run_collect_case "$candidate" "$label" "$filter" "$reports_dir" "$logs_dir"; then
      passed_count=$((passed_count + 1))
    else
      failed_count=$((failed_count + 1))
    fi
  done

  echo "[pgo-gather] reports root: $reports_root" >&2

  if [[ "$passed_count" -eq 0 ]]; then
    echo "[pgo-gather] all collect workloads failed; cannot gather usable profile" >&2
    exit 1
  fi

  if [[ "$failed_count" -gt 0 ]]; then
    echo "[pgo-gather] completed with partial failures: passed=$passed_count failed=$failed_count" >&2
  else
    echo "[pgo-gather] all collect workloads passed" >&2
  fi
}

if [[ -n "${KANO_CPP_INFRA_PGO_GATHER_COMMAND:-}" ]]; then
  (
    cd "$CPP_ROOT"
    eval "$KANO_CPP_INFRA_PGO_GATHER_COMMAND"
  )
  exit 0
fi

if [[ -n "${KOG_PGO_GATHER_COMMAND:-}" ]]; then
  (
    cd "$CPP_ROOT"
    eval "$KOG_PGO_GATHER_COMMAND"
  )
  exit 0
fi

run_collect_tests_default "$@"
