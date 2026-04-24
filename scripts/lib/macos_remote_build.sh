#!/usr/bin/env bash
# =============================================================================
# macOS Remote Build helper
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/remote_host_resolver.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common-remote.sh"

KANO_CMAKE_SEARCH_PATHS="${KANO_CMAKE_SEARCH_PATHS:-$HOME/bin/cmake/CMake.app/Contents/bin/cmake /usr/local/bin/cmake /usr/bin/cmake /opt/homebrew/bin/cmake}"
KANO_NINJA_SEARCH_PATHS="${KANO_NINJA_SEARCH_PATHS:-$HOME/bin/ninja /usr/local/bin/ninja /usr/bin/ninja /opt/homebrew/bin/ninja}"
KANO_REMOTE_BUILD_SSH_OPTS="${KANO_REMOTE_BUILD_SSH_OPTS:-${KOB_SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=10}}"
KANO_REMOTE_BUILD_SSH_OPTS_RSYNC="${KANO_REMOTE_BUILD_SSH_OPTS_RSYNC:-${KOB_SSH_OPTS_RSYNC:--o StrictHostKeyChecking=no -o ConnectTimeout=10}}"

inf_remote_build_local_host_name() {
    if [[ -n "${LOCAL_HOST_NAME:-}" ]]; then
        printf '%s' "$LOCAL_HOST_NAME"
        return 0
    fi

    hostname 2>/dev/null || uname -n 2>/dev/null || printf '%s' "unknown-host"
}

inf_remote_build_project_root() {
    local source_repo="$1"
    if [[ -z "$source_repo" || ! -d "$source_repo" ]]; then
        echo "inf_remote_build_project_root requires an existing source repo path" >&2
        return 1
    fi

    (
        cd "$source_repo"
        pwd -P
    )
}

inf_remote_build_default_dir() {
    local source_repo="$1"
    local local_host_name project_root

    local_host_name="$(inf_remote_build_local_host_name)"
    project_root="$(inf_remote_build_project_root "$source_repo")"
    printf '/tmp/remote/%s%s' "$local_host_name" "$project_root"
}

kano_cpp_remote_build_macos() {
    local source_repo="${1:-}"
    local remote_build_dir="${2:-}"
    local fallback_host="${3:-}"
    local configure_preset="${4:-}"
    local build_preset="${5:-}"
    local ssh_opts="${6:-$KANO_REMOTE_BUILD_SSH_OPTS}"
    local ssh_opts_rsync="${7:-$KANO_REMOTE_BUILD_SSH_OPTS_RSYNC}"

    if [[ -z "$source_repo" || -z "$configure_preset" || -z "$build_preset" ]]; then
        echo "kano_cpp_remote_build_macos requires source_repo, configure_preset, and build_preset" >&2
        return 1
    fi

    if [[ -z "$remote_build_dir" ]]; then
        remote_build_dir="$(inf_remote_build_default_dir "$source_repo")"
    fi

    local host_with_user=""
    local host_addr=""
    host_with_user="$(kano_cpp_pick_remote_host "${KANO_REMOTE_HOST_GROUP:-mac-local}" "${KANO_REMOTE_HOST_ROUTE:-auto}" "$fallback_host" || true)"
    if [[ -z "$host_with_user" ]]; then
        if [[ -n "$fallback_host" ]]; then
            host_with_user="$fallback_host"
        else
            echo "[ERROR] No remote macOS host resolved; set kano-remote-host config or provide a repo-local fallback." >&2
            return 1
        fi
    fi

    host_addr="${host_with_user#*@}"
    INF_REMOTE_BUILD_LAST_HOST="$host_with_user"
    INF_REMOTE_BUILD_LAST_ROOT="$remote_build_dir"
    export INF_REMOTE_BUILD_LAST_HOST INF_REMOTE_BUILD_LAST_ROOT

    echo "[INFO] Using macOS builder: $host_with_user"
    echo "[INFO] Remote build root: $remote_build_dir"

    echo "[INFO] Testing SSH connection to $host_with_user..."
    if ! ssh -o BatchMode=yes -q "$host_with_user" "echo 'SSH OK'" 2>/dev/null; then
        if ! ssh ${ssh_opts} -q "$host_with_user" "echo 'SSH OK'" 2>/dev/null; then
            echo "[ERROR] Cannot connect to $host_with_user" >&2
            return 1
        fi
    fi

    # Ensure we have a compatible rsync binary and detect remote rsync variant
    horizon_base_ensure_rsync || true
    local rsync_cmd=""
    rsync_cmd="$(horizon_base_resolve_rsync_cmd)"
    local rsync_protocol_flag=""
    rsync_protocol_flag="$(horizon_base_rsync_protocol_flag "$host_with_user" || echo "")"
    echo "[INFO] rsync command: $rsync_cmd  protocol flag: ${rsync_protocol_flag:-<none>}"

    echo "[INFO] Source sync -> $host_with_user:$remote_build_dir"
    "$rsync_cmd" -avz --delete \
        -e "ssh ${ssh_opts_rsync}" \
        ${rsync_protocol_flag} \
        --exclude 'out/' \
        --exclude 'build/' \
        --exclude '.git/' \
        --exclude 'node_modules/' \
        --exclude '__pycache__/' \
        --exclude '.kano/' \
        --exclude '.cache/' \
        "$source_repo/" \
        "$host_with_user:$remote_build_dir/"

    local cmake_path
    cmake_path="$(ssh ${ssh_opts} "$host_with_user" "
      for cmake in ${KANO_CMAKE_SEARCH_PATHS}; do
        if [[ -x \"\$cmake\" ]]; then
          echo \"\$cmake\"
          exit 0
        fi
      done
      echo \"ERROR: cmake not found\" >&2
      exit 1
    " )" || true
    if [[ "$cmake_path" == ERROR:* || -z "$cmake_path" ]]; then
        echo "[ERROR] ${cmake_path:-cmake not found}" >&2
        return 1
    fi

    local ninja_path
    ninja_path="$(ssh ${ssh_opts} "$host_with_user" "
      for ninja in ${KANO_NINJA_SEARCH_PATHS}; do
        if [[ -x \"\$ninja\" ]]; then
          echo \"\$ninja\"
          exit 0
        fi
      done
      echo \"ERROR: ninja not found\" >&2
      exit 1
    " )" || true
    if [[ "$ninja_path" == ERROR:* || -z "$ninja_path" ]]; then
        echo "[ERROR] ${ninja_path:-ninja not found}" >&2
        return 1
    fi

    echo "[INFO] Remote tools: cmake=$cmake_path ninja=$ninja_path"
    echo "[INFO] Remote execute: configure='$configure_preset' build='$build_preset'"
    ssh ${ssh_opts} "$host_with_user" "
      set -euo pipefail
      mkdir -p '$remote_build_dir'
      export PATH=\"$(dirname "$cmake_path"):$(dirname "$ninja_path"):\$PATH\"
      cd '$remote_build_dir'
      rm -rf out
      '$cmake_path' --preset '$configure_preset'
      '$cmake_path' --build --preset '$build_preset' -j\$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    "

    echo "[INFO] Build complete on $host_addr"
}

inf_remote_build_macos() {
    local in_configure_preset="${1:-}"
    local in_build_type="${2:-Release}"
    local source_repo="${INF_CPP_ROOT:-}"

    if [[ -z "$source_repo" ]]; then
        echo "[ERROR] INF_CPP_ROOT not set" >&2
        return 1
    fi

    local build_preset="${in_configure_preset}-${in_build_type,,}"
    local remote_build_dir="${KANO_REMOTE_BUILD_DIR:-${KOB_REMOTE_BUILD_DIR:-}}"
    local fallback_host="${KANO_REMOTE_BUILD_FALLBACK_HOST:-${KOB_MACBUILDER_HOST:-}}"

    kano_cpp_remote_build_macos \
        "$source_repo" \
        "$remote_build_dir" \
        "$fallback_host" \
        "$in_configure_preset" \
        "$build_preset" \
        "$KANO_REMOTE_BUILD_SSH_OPTS" \
        "$KANO_REMOTE_BUILD_SSH_OPTS_RSYNC"
}
