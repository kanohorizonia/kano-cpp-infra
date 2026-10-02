#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/native_tool.sh"
kano_cpp_infra_watchdog_enter "$0" "$@"


bash "$SCRIPT_DIR/../stages/coverage-build.sh" "$@"
bash "$SCRIPT_DIR/../stages/coverage-gather.sh" "$@"
exec bash "$SCRIPT_DIR/../stages/coverage-report.sh" "$@"
