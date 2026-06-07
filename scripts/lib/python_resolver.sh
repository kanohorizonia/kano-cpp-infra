#!/usr/bin/env bash

# Shared Python resolver for Git Bash, macOS, and Linux agents. Windows Store
# app execution aliases can make `command -v python` look valid while execution
# still fails, so each candidate is probed before use.

kano_python_command_works() {
  local candidate="${1:-}"
  local -a parts=()

  [[ -n "$candidate" ]] || return 1

  if [[ -f "$candidate" || -x "$candidate" ]]; then
    "$candidate" -c 'import sys' >/dev/null 2>&1
    return $?
  fi

  # shellcheck disable=SC2206
  parts=( $candidate )
  [[ ${#parts[@]} -gt 0 ]] || return 1
  "${parts[@]}" -c 'import sys' >/dev/null 2>&1
}

kano_python_add_candidate() {
  local candidate="${1:-}"
  local existing

  [[ -n "$candidate" ]] || return 0
  for existing in "${KANO_PYTHON_CANDIDATES[@]:-}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  KANO_PYTHON_CANDIDATES+=("$candidate")
}

kano_python_add_command_paths() {
  local command_name="$1"
  local path

  while IFS= read -r path; do
    kano_python_add_candidate "$path"
  done < <(type -P -a "$command_name" 2>/dev/null || true)
}

kano_python_add_windows_candidates() {
  local path

  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) return 0 ;;
  esac

  for path in \
    /c/Python*/python.exe \
    /c/Users/*/AppData/Local/Programs/Python/Python*/python.exe \
    /c/Program\ Files/Python*/python.exe; do
    [[ -x "$path" ]] && kano_python_add_candidate "$path"
  done
}

kano_resolve_python_bin() {
  KANO_PYTHON_CANDIDATES=()

  kano_python_add_candidate "${KANO_PYTHON:-}"
  kano_python_add_command_paths python3
  kano_python_add_command_paths python
  kano_python_add_command_paths py
  kano_python_add_windows_candidates
  kano_python_add_candidate "python3"
  kano_python_add_candidate "py"
  kano_python_add_candidate "python"

  local candidate
  for candidate in "${KANO_PYTHON_CANDIDATES[@]}"; do
    if kano_python_command_works "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "python3, py, or python is required." >&2
  return 1
}

kano_python() {
  local candidate="${1:-}"
  local -a parts=()
  shift || true

  if [[ -f "$candidate" || -x "$candidate" ]]; then
    "$candidate" "$@"
    return $?
  fi

  # shellcheck disable=SC2206
  parts=( $candidate )
  "${parts[@]}" "$@"
}
