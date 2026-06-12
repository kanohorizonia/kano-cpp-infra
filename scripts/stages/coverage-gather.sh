#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/matrix.sh"

INFRA_SCRIPTS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
INFRA_BASE_DIR="$(cd -- "$INFRA_SCRIPTS_DIR/.." && pwd)"
CPP_ROOT="$(cd -- "$INFRA_BASE_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$CPP_ROOT/../.." && pwd)"

export INF_CPP_ROOT="${INF_CPP_ROOT:-$CPP_ROOT}"
export KANO_CPP_ROOT="${KANO_CPP_ROOT:-$CPP_ROOT}"
export KANO_CPP_INFRA_CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$CPP_ROOT}"
export KANO_CPP_INFRA_REPO_ROOT="${KANO_CPP_INFRA_REPO_ROOT:-$REPO_ROOT}"
resolve_repo_path() {
  local raw_path="${1:-}"
  local normalized
  if [[ -z "$raw_path" ]]; then
    return 0
  fi
  normalized="${raw_path//\\//}"
  if command -v cygpath >/dev/null 2>&1 && [[ "$normalized" =~ ^[A-Za-z]:/ ]]; then
    cygpath -u "$normalized"
    return 0
  fi
  if [[ "$normalized" == /* ]]; then
    printf '%s\n' "$normalized"
    return 0
  fi
  normalized="${normalized#./}"
  printf '%s/%s\n' "${REPO_ROOT%/}" "$normalized"
}
if [[ -z "${INF_COVERAGE_ROOT:-}" ]]; then
  if [[ -n "${KANO_COVERAGE_REPORT_DIR:-}" ]]; then
    export KANO_COVERAGE_REPORT_DIR="$(resolve_repo_path "$KANO_COVERAGE_REPORT_DIR")"
    export INF_COVERAGE_ROOT="$KANO_COVERAGE_REPORT_DIR"
  elif [[ -n "${KANO_COVERAGE_REPORTS_ROOT:-}" && -n "${KANO_REPORT_SLUG:-}" ]]; then
    export KANO_COVERAGE_REPORTS_ROOT="$(resolve_repo_path "$KANO_COVERAGE_REPORTS_ROOT")"
    export INF_COVERAGE_ROOT="$KANO_COVERAGE_REPORTS_ROOT/$KANO_REPORT_SLUG"
  fi
fi

coverage_script="$(kano_cpp_infra_matrix_default_coverage_gather_script)"
default_args=()
case "$(kano_cpp_infra_matrix_host_os)" in
  win64)
    configure_preset="$(kano_cpp_infra_matrix_default_coverage_configure_preset || true)"
    if [[ -n "$configure_preset" ]]; then
      default_args=("$configure_preset")
    fi
    ;;
esac

if [[ "$#" -eq 0 ]]; then
  bash "$coverage_script" test "${default_args[@]}"
  exec bash "$coverage_script" merge
fi

bash "$coverage_script" test "$@"
exec bash "$coverage_script" merge
