#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/../lib/native_tool.sh"

MATRIX_NAME="${1:-default}"
MATRIX_PATH="$(inf_profile_require_matrix "$MATRIX_NAME")"

kano_cpp_infra_tool render-profile-report "$MATRIX_PATH" "$INF_PROFILE_TMP_ROOT" "$INF_PROFILE_REPORT_ROOT"
