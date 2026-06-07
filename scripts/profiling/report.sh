#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

MATRIX_NAME="${1:-default}"
MATRIX_PATH="$(inf_profile_require_matrix "$MATRIX_NAME")"

PYTHON_BIN="$(kano_resolve_python_bin)"
kano_python "$PYTHON_BIN" "$SCRIPT_DIR/render_profile_report.py" "$MATRIX_PATH" "$INF_PROFILE_TMP_ROOT" "$INF_PROFILE_REPORT_ROOT"
