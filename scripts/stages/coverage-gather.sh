#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/matrix.sh"

coverage_script="$(kano_cpp_infra_matrix_default_coverage_gather_script)"
exec bash "$coverage_script" "$@"
