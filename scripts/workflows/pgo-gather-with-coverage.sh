#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

export KANO_CXX_PROFILE_RUN_MODE="pgo-gather-with-coverage"
export KANO_CPP_INFRA_PGO_REBUILD_SKIP_USE=1

if [[ -z "${KANO_CXX_COVERAGE_PROVIDER:-}" && -z "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" ]]; then
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*)
      export KANO_CPP_INFRA_COVERAGE_TOOL="opencppcoverage"
      ;;
    *)
      export KANO_CPP_INFRA_COVERAGE_TOOL="llvm"
      ;;
  esac
fi

exec bash "$SCRIPT_DIR/pgo-rebuild.sh"
