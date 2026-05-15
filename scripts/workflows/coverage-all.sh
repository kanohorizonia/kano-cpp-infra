#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/../stages/coverage-build.sh" "$@"
bash "$SCRIPT_DIR/../stages/coverage-gather.sh" "$@"
exec bash "$SCRIPT_DIR/../stages/coverage-report.sh" "$@"
