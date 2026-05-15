#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

MATRIX_NAME="${1:-default}"
MATRIX_PATH="$(inf_profile_require_matrix "$MATRIX_NAME")"

python "$SCRIPT_DIR/run_matrix.py" "$MATRIX_PATH" "$INF_PROFILE_TMP_ROOT" "$INF_PROFILE_REPO_ROOT" "$INF_PROFILE_CPP_ROOT"
