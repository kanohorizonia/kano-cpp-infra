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

run_collect_tests_default() {
  local preset_name
  local bin_root
  local exe_ext=""
  local test_bin
  local passed_count=0
  local failed_count=0

  preset_name="$(resolve_collect_preset)"
  bin_root="$CPP_ROOT/out/bin/$preset_name/debug"

  if [[ "$(uname -s 2>/dev/null || true)" == MINGW* || "$(uname -s 2>/dev/null || true)" == MSYS* || "$(uname -s 2>/dev/null || true)" == CYGWIN* ]]; then
    exe_ext=".exe"
  fi

  for test_bin in kano_git_cli_tests kano_git_tui_tests kano_git_commit_plan_tests kano_git_export_tests; do
    local candidate="$bin_root/$test_bin$exe_ext"
    if [[ ! -f "$candidate" ]]; then
      echo "[pgo-gather] missing collect test binary: $candidate" >&2
      exit 1
    fi

    echo "[pgo-gather] running $candidate" >&2
    if "$candidate"; then
      passed_count=$((passed_count + 1))
    else
      failed_count=$((failed_count + 1))
      echo "[pgo-gather] warning: $candidate failed; continue gathering remaining workloads" >&2
    fi
  done

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
