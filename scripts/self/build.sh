#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/native_tool.sh"
kano_cpp_infra_watchdog_enter "$0" "$@"

CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"
export KANO_CPP_ROOT="$CPP_ROOT"

. "$CPP_ROOT/shared/infra/scripts/lib/matrix.sh"
build_script="$(kano_cpp_infra_matrix_default_release_script)"
exec bash "$build_script" "$@"
