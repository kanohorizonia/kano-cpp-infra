#!/usr/bin/env bash
# =============================================================================
# macOS Remote Build helper
# =============================================================================
set -euo pipefail

KOB_MACBUILDER_HOST="${KOB_MACBUILDER_HOST:-dorgon.chang@macbuilder.cobia-tailor.ts.net}"
KOB_REMOTE_BUILD_DIR="${KOB_REMOTE_BUILD_DIR:-/tmp/kano-build}"
KOB_SSH_OPTS="${KOB_SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=10}"
KOB_SSH_OPTS_RSYNC="${KOB_SSH_OPTS_RSYNC:-o StrictHostKeyChecking=no -o ConnectTimeout=10}"

kog_remote_build_macos() {
    local in_configure_preset="${1:-}"
    local in_build_type="${2:-Release}"
    local source_repo="${KOG_CPP_ROOT:-}"

    if [[ -z "$source_repo" ]]; then
        echo "[ERROR] KOG_CPP_ROOT not set" >&2
        return 1
    fi

    local build_preset="${in_configure_preset}-${in_build_type,,}"
    kano_cpp_remote_build_macos \
        "$source_repo" \
        "$KOB_REMOTE_BUILD_DIR" \
        "$KOB_MACBUILDER_HOST" \
        "$in_configure_preset" \
        "$build_preset" \
        "$KOB_SSH_OPTS" \
        "$KOB_SSH_OPTS_RSYNC"
}
