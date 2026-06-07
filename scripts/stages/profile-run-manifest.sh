#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"
PYTHON_RESOLVER_SH="$CPP_ROOT/shared/infra/scripts/lib/python_resolver.sh"

mode="${KANO_CXX_PROFILE_RUN_MODE:-${1:-pgo-rebuild}}"
out="${KANO_CXX_PROFILE_MANIFEST:-$CPP_ROOT/.kano/tmp/profile/profile-run-manifest.json}"

compiler="${KANO_CXX_COMPILER:-}"
if [[ -z "$compiler" ]]; then
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) compiler="msvc" ;;
    *) compiler="clang" ;;
  esac
fi

# shellcheck source=/dev/null
source "$PYTHON_RESOLVER_SH"
PYTHON_BIN="$(kano_resolve_python_bin)"

coverage_provider="${KANO_CXX_COVERAGE_PROVIDER:-${KANO_CPP_INFRA_COVERAGE_TOOL:-none}}"
pgo_provider="${KANO_CXX_PGO_PROVIDER:-}"
if [[ -z "$pgo_provider" ]]; then
  if [[ "$compiler" == "msvc" ]]; then
    pgo_provider="msvc-pgo"
  elif [[ "$compiler" == "clang" ]]; then
    pgo_provider="llvm-profdata"
  else
    pgo_provider="none"
  fi
fi

args=(
  --compiler "$compiler"
  --coverage-provider "$coverage_provider"
  --pgo-provider "$pgo_provider"
  --profile-run-mode "$mode"
  --out "$out"
)

if [[ "${KANO_CXX_COVERAGE_MODE:-}" == "server" ]]; then
  args+=(--microsoft-server-mode)
fi

if [[ -n "${KANO_CXX_TRAINING_COMMAND:-}" ]]; then
  args+=(--training-command "$KANO_CXX_TRAINING_COMMAND")
fi
if [[ -n "${KANO_CXX_COVERAGE_COMMAND:-}" ]]; then
  args+=(--coverage-command "$KANO_CXX_COVERAGE_COMMAND")
fi
if [[ -n "${KANO_CXX_PGO_DATA_PATHS:-}" ]]; then
  args+=(--pgo-data-paths "$KANO_CXX_PGO_DATA_PATHS")
fi
if [[ -n "${KANO_CXX_COVERAGE_REPORT_PATHS:-}" ]]; then
  args+=(--coverage-report-paths "$KANO_CXX_COVERAGE_REPORT_PATHS")
fi

kano_python "$PYTHON_BIN" "$CPP_ROOT/shared/infra/scripts/profiling/profile_run_capabilities.py" "${args[@]}"
echo "[profile-run] manifest: $out" >&2
