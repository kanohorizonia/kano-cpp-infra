#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"

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
