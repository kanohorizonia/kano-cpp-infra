#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/native_tool.sh"
kano_cpp_infra_watchdog_enter "$0" "$@"

CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"

kano_cpp_infra_test_timeout_audit "$CPP_ROOT" "${KANO_TEST_CONFIG:-Release}"

if [[ -n "${KANO_CPP_INFRA_TEST_COMMAND:-}" ]]; then
  (
    cd "$CPP_ROOT"
    eval "$KANO_CPP_INFRA_TEST_COMMAND" "$@"
  )
else
  if [[ -n "${KOG_TEST_COMMAND:-}" ]]; then
    (
      cd "$CPP_ROOT"
      eval "$KOG_TEST_COMMAND" "$@"
    )
  else
    exec bash "$CPP_ROOT/code/tests/run_tests.sh" "$@"
  fi
fi
