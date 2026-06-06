#!/usr/bin/env bash
set -euo pipefail

kano_cpp_docker_host_uname() {
  uname -s 2>/dev/null || echo "unknown"
}

kano_cpp_docker_is_windows_shell() {
  case "$(kano_cpp_docker_host_uname)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

kano_cpp_docker_resolve_dir() {
  local input_path="${1:-}"
  if [[ -z "$input_path" ]]; then
    echo "docker host path is required." >&2
    return 1
  fi
  (cd "$input_path" >/dev/null 2>&1 && pwd -P)
}

kano_cpp_docker_host_path_for_cli() {
  local input_path="${1:-}"
  local resolved=""
  local windows_path=""

  resolved="$(kano_cpp_docker_resolve_dir "$input_path")" || {
    echo "Unable to resolve docker host path: $input_path" >&2
    return 1
  }

  if kano_cpp_docker_is_windows_shell; then
    if command -v cygpath >/dev/null 2>&1; then
      cygpath -m "$resolved"
      return 0
    fi
    windows_path="$(cd "$resolved" >/dev/null 2>&1 && pwd -W 2>/dev/null || true)"
    if [[ -z "$windows_path" ]]; then
      echo "Unable to convert docker host path for Windows shell: $resolved" >&2
      return 1
    fi
    printf '%s\n' "${windows_path//\\//}"
    return 0
  fi

  printf '%s\n' "$resolved"
}

kano_cpp_docker_volume_arg() {
  local input_path="${1:-}"
  local container_path="${2:-}"
  local mode="${3:-rw}"
  local host_path=""
  local suffix=""

  if [[ -z "$container_path" ]]; then
    echo "docker container path is required." >&2
    return 1
  fi

  host_path="$(kano_cpp_docker_host_path_for_cli "$input_path")" || return 1

  case "$mode" in
    rw|"")
      suffix=""
      ;;
    ro)
      suffix=":ro"
      ;;
    *)
      echo "Unsupported docker volume mode: $mode" >&2
      return 1
      ;;
  esac

  printf '%s:%s%s\n' "$host_path" "$container_path" "$suffix"
}

kano_cpp_docker_run() {
  if kano_cpp_docker_is_windows_shell; then
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"
    return $?
  fi
  docker "$@"
}
