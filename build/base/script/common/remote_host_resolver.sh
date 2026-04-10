#!/usr/bin/env bash
set -euo pipefail

_kano_cpp_extract_json_string() {
  local json_input="$1"
  local key_name="$2"
  local line=""

  line="$(printf '%s' "$json_input" | tr -d '\r\n' | sed -n "s/.*\"${key_name}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")"
  printf '%s' "$line"
}

kano_cpp_remote_host_cli() {
  local configured="${KANO_REMOTE_HOST_BIN:-kano-remote-host}"
  if [[ "$configured" == */* || "$configured" == *\\* ]]; then
    if [[ -x "$configured" ]]; then
      printf '%s' "$configured"
      return 0
    fi
    return 1
  fi

  if command -v "$configured" >/dev/null 2>&1; then
    command -v "$configured"
    return 0
  fi

  return 1
}

kano_cpp_pick_remote_host() {
  local host_group="${1:-}"
  local route_mode="${2:-auto}"
  local fallback_host="${3:-}"
  local cli_path=""
  local resolver_output=""
  local resolved_host=""

  if [[ -z "$host_group" ]]; then
    echo "kano_cpp_pick_remote_host requires a host group" >&2
    return 1
  fi

  if cli_path="$(kano_cpp_remote_host_cli)"; then
    echo "[INFO] Resolving remote host via ${cli_path} pick ${host_group} --route ${route_mode}..." >&2
    if resolver_output="$(${cli_path} pick "$host_group" --route "$route_mode" 2>&1)"; then
      resolved_host="$(_kano_cpp_extract_json_string "$resolver_output" "address_with_user")"
      if [[ -z "$resolved_host" || "$resolved_host" == "null" ]]; then
        resolved_host="$(_kano_cpp_extract_json_string "$resolver_output" "address")"
      fi
      if [[ -n "$resolved_host" && "$resolved_host" != "null" ]]; then
        printf '%s' "$resolved_host"
        return 0
      fi
      echo "[WARN] remote host resolver returned no usable address" >&2
    else
      echo "[WARN] remote host resolver failed: $resolver_output" >&2
    fi
  else
    echo "[INFO] remote host resolver CLI not found; checking fallback host" >&2
  fi

  if [[ -n "$fallback_host" ]]; then
    printf '%s' "$fallback_host"
    return 0
  fi

  return 1
}
