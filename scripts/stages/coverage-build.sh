#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/matrix.sh"

coverage_script="$(inf_matrix_default_coverage_build_script)"
exec bash "$coverage_script" "$@"
