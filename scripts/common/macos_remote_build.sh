#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/remote_host_resolver.sh"

KANO_CMAKE_SEARCH_PATHS="${KANO_CMAKE_SEARCH_PATHS:-$HOME/bin/cmake/CMake.app/Contents/bin/cmake /usr/local/bin/cmake /usr/bin/cmake /opt/homebrew/bin/cmake}"
KANO_NINJA_SEARCH_PATHS="${KANO_NINJA_SEARCH_PATHS:-$HOME/bin/ninja /usr/local/bin/ninja /usr/bin/ninja /opt/homebrew/bin/ninja}"

kano_cpp_remote_build_macos() {
  local source_repo="${1:-}"
  local remote_build_dir="${2:-}"
  local fallback_host="${3:-}"
  local configure_preset="${4:-}"
  local build_preset="${5:-}"
  local ssh_opts="${6:--o StrictHostKeyChecking=no -o ConnectTimeout=10}"
  local ssh_opts_rsync="${7:--o StrictHostKeyChecking=no -o ConnectTimeout=10}"

  if [[ -z "$source_repo" || -z "$remote_build_dir" || -z "$fallback_host" || -z "$configure_preset" || -z "$build_preset" ]]; then
    echo "kano_cpp_remote_build_macos requires source_repo, remote_build_dir, fallback_host, configure_preset, and build_preset" >&2
    return 1
  fi

  local host_with_user=""
  local host_addr=""
  host_with_user="$(kano_cpp_pick_remote_host "${KANO_REMOTE_HOST_GROUP:-mac-local}" "${KANO_REMOTE_HOST_ROUTE:-auto}" "$fallback_host" || true)"
  if [[ -z "$host_with_user" ]]; then
    host_with_user="$fallback_host"
  fi
  host_addr="${host_with_user#*@}"
  echo "[INFO] Using macOS builder: $host_with_user"

  echo "[INFO] Testing SSH connection to $host_with_user..."
  if ! ssh -o BatchMode=yes -q ${host_with_user:+${host_with_user}} "echo 'SSH OK'" 2>/dev/null; then
    if ! ssh ${ssh_opts} -q "$host_with_user" "echo 'SSH OK'" 2>/dev/null; then
      echo "[ERROR] Cannot connect to $host_with_user" >&2
      return 1
    fi
  fi

  echo "[INFO] Rsyncing source to $host_with_user:${remote_build_dir}..."
  rsync -avz --delete \
    -e "ssh ${ssh_opts_rsync}" \
    --exclude 'out/' \
    --exclude 'build/' \
    --exclude '.git/' \
    --exclude 'node_modules/' \
    --exclude '__pycache__/' \
    --exclude '.kano/' \
    --exclude '.cache/' \
    "${source_repo}/" \
    "${host_with_user}:${remote_build_dir}/" 2>&1 | tail -5

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
  ")" || true
  if [[ "$cmake_path" == ERROR:* ]]; then
    echo "[ERROR] $cmake_path" >&2
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
  ")" || true
  if [[ "$ninja_path" == ERROR:* ]]; then
    echo "[ERROR] $ninja_path" >&2
    return 1
  fi

  echo "[INFO] Remote tools: cmake=$cmake_path ninja=$ninja_path"
  echo "[INFO] Building configure='$configure_preset' build='$build_preset'..."

  ssh ${ssh_opts} "$host_with_user" "
    set -euo pipefail
    export PATH=\"$(dirname "$cmake_path"):$(dirname "$ninja_path"):\$PATH\"
    cd '${remote_build_dir}'
    rm -rf out
    '$cmake_path' --preset '${configure_preset}'
    '$cmake_path' --build --preset '${build_preset}' -j\$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
  "

  echo "[INFO] Build complete on $host_addr"
}
