#!/usr/bin/env bash
# =============================================================================
# Cross-platform remote transport helpers
#
# Provides:
#   horizon_base_rsync_protocol_flag  — detect openrsync vs standard rsync
#   horizon_base_ensure_rsync          — lazy-download MSYS2 rsync to ~/bin/
#   horizon_base_resolve_rsync_cmd     — resolution order for rsync binary
# =============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# horizon_base_rsync_protocol_flag
# ─────────────────────────────────────────────────────────────────────────────
# SSH to the remote host and detect rsync variant.
# Returns --protocol=29 for standard rsync, empty string for openrsync.
#
# openrsync (used on macOS build agents) does not accept --protocol=29.
# Passing the flag causes it to misparse paths, producing:
#   rsync: source and destination cannot both be remote
horizon_base_rsync_protocol_flag() {
    local remote_host="${1:-}"
    if [[ -z "$remote_host" ]]; then
        echo "[horizon_base] rsync_protocol_flag: remote_host required" >&2
        return 1
    fi

    local remote_rsync_version=""
    remote_rsync_version="$(ssh "$remote_host" rsync --version 2>/dev/null | head -1)" || true

    if [[ "$remote_rsync_version" == *"openrsync"* ]]; then
        echo ""
    else
        echo "--protocol=29"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# horizon_base_ensure_rsync
# ─────────────────────────────────────────────────────────────────────────────
# Lazily download MSYS2 rsync 3.4.1 to ~/bin/rsync.exe if no usable rsync
# exists.  Uses native archive tools to decompress the .pkg.tar.zst container
# and extracts just the usr/bin/rsync.exe entry.
#
# Avoids modifying MSYS2 installations or pixi environments.
# Self-contained: the extracted binary carries its own runtime expectations.
horizon_base_ensure_rsync() {
    local rsync_cache="${HOME}/bin/rsync.exe"
    local msys2_url="https://repo.msys2.org/msys/x86_64/rsync-3.4.1-1-x86_64.pkg.tar.zst"
    local pkg_file="${HOME}/.cache/rsync-3.4.1-1-x86_64.pkg.tar.zst"

    # Already cached and executable — nothing to do
    if [[ -x "$rsync_cache" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$rsync_cache")" "$(dirname "$pkg_file")"

    # Download once
    if [[ ! -f "$pkg_file" ]]; then
        echo "[horizon_base] Downloading MSYS2 rsync -> $pkg_file" >&2
        curl -L -o "$pkg_file" "$msys2_url"
    fi

    # Decompress with native archive tools, then extract rsync.exe from the tar layer.
    echo "[horizon_base] Extracting rsync.exe from $pkg_file" >&2
    local extract_tmp="${HOME}/.cache/rsync-3.4.1-extract"
    rm -rf -- "$extract_tmp"
    mkdir -p "$extract_tmp"

    if tar --help 2>/dev/null | grep -q -- '--zstd'; then
        tar --zstd -xf "$pkg_file" -C "$extract_tmp"
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$pkg_file" -C "$extract_tmp"
    elif command -v zstd >/dev/null 2>&1; then
        zstd -dc "$pkg_file" | tar -xf - -C "$extract_tmp"
    else
        echo "[horizon_base] ERROR: extracting rsync requires tar with zstd support, bsdtar, or zstd." >&2
        return 1
    fi

    local extracted_rsync=""
    extracted_rsync="$(find "$extract_tmp" -type f -name 'rsync.exe' | head -n 1 || true)"
    if [[ -n "$extracted_rsync" ]]; then
        cp -f "$extracted_rsync" "$rsync_cache"
        chmod +x "$rsync_cache" 2>/dev/null || true
    fi

    if [[ ! -x "$rsync_cache" ]]; then
        echo "[horizon_base] ERROR: rsync extraction failed, rsync.exe not found at $rsync_cache" >&2
        return 1
    fi

    echo "[horizon_base] rsync ready at $rsync_cache" >&2
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# horizon_base_resolve_rsync_cmd
# ─────────────────────────────────────────────────────────────────────────────
# Resolution order:
#   1. ~/bin/rsync.exe  (cached MSYS2 binary)
#   2. system rsync     (via command -v)
horizon_base_resolve_rsync_cmd() {
    local cache_rsync="${HOME}/bin/rsync.exe"
    if [[ -x "$cache_rsync" ]]; then
        echo "$cache_rsync"
        return 0
    fi
    if command -v rsync &>/dev/null; then
        echo "rsync"
        return 0
    fi
    echo "[horizon_base] WARNING: no rsync found; operations requiring rsync will fail" >&2
    echo "rsync"
    return 0
}
