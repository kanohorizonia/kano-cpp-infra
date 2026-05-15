#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/matrix.sh"

backend="${1:-default}"
if [[ "$#" -gt 0 ]]; then
  shift
fi

coverage_script="$(kano_cpp_infra_matrix_default_coverage_report_script "$backend")"
exec bash "$coverage_script" "$@"
