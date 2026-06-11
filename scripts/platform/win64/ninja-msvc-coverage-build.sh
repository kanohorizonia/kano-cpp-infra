#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/matrix.sh"
source "$SCRIPT_DIR/../../lib/windows_preset_build.sh"

configure_preset="${KANO_CPP_INFRA_COVERAGE_CONFIGURE_PRESET:-$(kano_cpp_infra_matrix_default_coverage_configure_preset)}"
build_preset="${KANO_CPP_INFRA_COVERAGE_BUILD_PRESET:-$(kano_cpp_infra_matrix_default_coverage_build_preset)}"

kano_windows_run_preset "$configure_preset" "$build_preset" "x64"
