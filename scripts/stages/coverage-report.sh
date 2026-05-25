#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/matrix.sh"

backend="default"
default_command=(report)
if [[ -z "${INF_CPP_ROOT:-}" ]]; then
  INF_CPP_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
  export INF_CPP_ROOT
fi

case "$(kano_cpp_infra_matrix_host_os)" in
  win64) default_command=(report windows-ninja-msvc-coverage) ;;
esac

if [[ "$#" -gt 0 ]]; then
  case "$1" in
    build|test|run-tests|merge|report|all|info|help|--help|-h)
      ;;
    *)
      backend="$1"
      shift
      ;;
  esac
fi

coverage_script="$(kano_cpp_infra_matrix_default_coverage_report_script "$backend")"
if [[ "$#" -eq 0 ]]; then
  exec bash "$coverage_script" "${default_command[@]}"
fi

exec bash "$coverage_script" "$@"
