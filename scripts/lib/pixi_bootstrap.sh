#!/usr/bin/env bash
set -euo pipefail

KANO_PIXI_BOOTSTRAP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kano_pixi_bootstrap_have_command() {
  command -v "$1" >/dev/null 2>&1
}

kano_pixi_bootstrap_cpp_root() {
  if [[ -n "${KANO_CPP_ROOT:-${INF_CPP_ROOT:-${KOB_CPP_ROOT:-${KABSD_CPP_ROOT:-}}}}" ]]; then
    printf '%s\n' "${KANO_CPP_ROOT:-${INF_CPP_ROOT:-${KOB_CPP_ROOT:-${KABSD_CPP_ROOT:-}}}}"
    return 0
  fi
  cd "$KANO_PIXI_BOOTSTRAP_SCRIPT_DIR/../../../../" && pwd
}

kano_pixi_bootstrap_repo_root() {
  local cpp_root=""
  cpp_root="$(kano_pixi_bootstrap_cpp_root)"
  cd "$cpp_root/../.." && pwd
}

kano_pixi_bootstrap_infra_root() {
  local cpp_root=""
  cpp_root="$(kano_pixi_bootstrap_cpp_root)"
  cd "$cpp_root/shared/infra" && pwd
}

kano_pixi_bootstrap_manifest_path() {
  if [[ -n "${KANO_PIXI_MANIFEST_PATH:-}" ]]; then
    printf '%s\n' "$KANO_PIXI_MANIFEST_PATH"
    return 0
  fi
  printf '%s/pixi.toml\n' "$(kano_pixi_bootstrap_infra_root)"
}

kano_pixi_bootstrap_global_tool_manifest_path() {
  printf '%s/pixi-global-tool.toml\n' "$(kano_pixi_bootstrap_infra_root)"
}

# Expose pixi global tools to PATH if they are installed.
# Does not install anything — only adds pixi's global bin dir to PATH.
# Returns 0 if the global bin dir exists and is now on PATH; non-zero otherwise.
kano_pixi_bootstrap_expose_global_tools() {
  local global_bin=""

  if ! command -v pixi >/dev/null 2>&1; then
    return 1
  fi

  # pixi global install exposes binaries through PIXI_HOME/bin.
  local pixi_home="${PIXI_HOME:-${HOME}/.pixi}"
  global_bin="$pixi_home/bin"
  if [[ ! -d "$global_bin" ]]; then
    return 1
  fi

  # Prepend global bin to PATH (idempotent — don't duplicate)
  if [[ ":$PATH:" != *":$global_bin:"* ]]; then
    export PATH="$global_bin:$PATH"
  fi

  return 0
}

kano_pixi_bootstrap_env_name() {
  printf '%s\n' "${KANO_PIXI_ENVIRONMENT_NAME:-default}"
}

_kano_pixi_bootstrap_normalize_path() {
  local in_path="$1"
  if [[ -z "$in_path" ]]; then
    return 0
  fi
  if [[ -d "$in_path" ]]; then
    cd "$in_path" && pwd -P
    return 0
  fi
  if [[ -e "$in_path" ]]; then
    local parent=""
    parent="$(cd "$(dirname "$in_path")" && pwd -P)"
    printf '%s/%s\n' "$parent" "$(basename "$in_path")"
    return 0
  fi
  printf '%s\n' "$in_path"
}

kano_pixi_bootstrap_is_active() {
  local expected_project_root=""
  local expected_env=""
  local active_project_root=""

  expected_project_root="$(_kano_pixi_bootstrap_normalize_path "$(dirname "$(kano_pixi_bootstrap_manifest_path)")")"
  expected_env="$(kano_pixi_bootstrap_env_name)"
  active_project_root="$(_kano_pixi_bootstrap_normalize_path "${PIXI_PROJECT_ROOT:-}")"

  [[ "${PIXI_IN_SHELL:-}" == "1" ]] || return 1
  [[ -n "$active_project_root" && "$active_project_root" == "$expected_project_root" ]] || return 1
  [[ -z "${PIXI_ENVIRONMENT_NAME:-}" || "${PIXI_ENVIRONMENT_NAME:-}" == "$expected_env" ]] || return 1
  return 0
}

kano_pixi_bootstrap_activate() {
  # Resolve PIXI_HOME: on Windows (Git Bash / MSYS2), $HOME may point to a
  # POSIX-style path that differs from USERPROFILE where pixi is actually
  # installed. Prefer USERPROFILE-derived path when the pixi bin dir exists
  # there and PIXI_HOME is not already set explicitly.
  if [[ -z "${PIXI_HOME:-}" ]]; then
    local _win_pixi_home=""
    # Git Bash / MSYS2 / Cygwin: USERPROFILE is a Windows path like C:\Users\foo
    if [[ -n "${USERPROFILE:-}" ]]; then
      # Convert backslashes and drive letter to POSIX path
      if command -v cygpath >/dev/null 2>&1; then
        _win_pixi_home="$(cygpath -u "${USERPROFILE}")"
      else
        _win_pixi_home="$(printf '%s' "${USERPROFILE}" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/\L\1|')"
      fi
    fi
    if [[ -n "$_win_pixi_home" && -d "${_win_pixi_home}/.pixi/bin" ]]; then
      export PIXI_HOME="${_win_pixi_home}/.pixi"
    else
      export PIXI_HOME="${HOME}/.pixi"
    fi
  fi

  local manifest_path=""
  local env_name=""
  local pixi_cmd=""

  manifest_path="$(kano_pixi_bootstrap_manifest_path)"
  env_name="$(kano_pixi_bootstrap_env_name)"

  # -----------------------------------------------------------------------
  # Global-first strategy: try to expose pixi global tools first, then
  # check if all required build tools are available in PATH.
  # If global tools are installed (via pixi global install --expose), use them
  # and skip project-local activation to avoid workspace env overhead.
  # -----------------------------------------------------------------------
  kano_pixi_bootstrap_expose_global_tools || true

  if kano_pixi_bootstrap_have_command cmake && \
     kano_pixi_bootstrap_have_command ninja && \
     kano_pixi_bootstrap_have_command git; then
    # Global tools sufficient — use them directly without pixi activation
    printf '[pixi-bootstrap] use global tools from ~/.pixi\n' >&2
    local cpp_root=""
    cpp_root="$(kano_pixi_bootstrap_cpp_root)"
    if [[ -n "$cpp_root" ]]; then
      export KANO_CPP_ROOT="$cpp_root"
    fi
    return 0
  fi

  # Global tools insufficient (or not yet installed) — fall through to
  # project-local activation for this workspace.
  if kano_pixi_bootstrap_is_active; then
    printf '[pixi-bootstrap] reuse env=%s manifest=%s\n' "$env_name" "$manifest_path" >&2
    return 0
  fi

  if [[ ! -f "$manifest_path" ]]; then
    printf '[pixi-bootstrap] manifest missing; leaving PATH unchanged: %s\n' "$manifest_path" >&2
    return 0
  fi

  # Fix TMP for Windows — pixi shell-hook sets TMP to protected C:\WINDOWS\.tmpXXX
  # which causes permission-denied errors. Override with user-writable path.
  export TMP="${TMP:-${TEMP:-/tmp}}"

  if ! pixi_cmd="$(command -v pixi 2>/dev/null)"; then
    local candidate
    for candidate in \
      "${PIXI_HOME:-}/bin/pixi" \
      "${USERPROFILE:-}/.pixi/bin/pixi" \
      "${HOME}/.pixi/bin/pixi"; do
      if [[ -n "$candidate" && -x "$candidate" ]]; then
        pixi_cmd="$candidate"
        export PATH="$(dirname "$pixi_cmd"):$PATH"
        break
      fi
    done
  fi

  if [[ -z "$pixi_cmd" ]]; then
    printf '[pixi-bootstrap] ERROR: manifest exists but pixi not found; fail-fast: %s\n' "$manifest_path" >&2
    return 1
  fi

  eval "$("$pixi_cmd" shell-hook --manifest-path "$manifest_path" --environment "$env_name")"
  printf '[pixi-bootstrap] activated env=%s manifest=%s\n' "$env_name" "$manifest_path" >&2

  # Export KANO_CPP_ROOT so callers get the correct infra root
  local cpp_root=""
  cpp_root="$(kano_pixi_bootstrap_cpp_root)"
  if [[ -n "$cpp_root" ]]; then
    export KANO_CPP_ROOT="$cpp_root"
  fi
}

# Install the global toolchain defined in pixi-global-tool.toml.
# Idempotent — safe to run multiple times. Fails fast if pixi is unavailable.
# Called by: kog self install-prereq (via prerequisite-*.sh scripts).
#
# Uses batch install (all packages at once) for efficiency.
kano_pixi_bootstrap_install_global_tools() {
  local manifest_path=""
  local pixi_cmd=""
  local platform=""

  manifest_path="$(kano_pixi_bootstrap_global_tool_manifest_path)"
  if [[ ! -f "$manifest_path" ]]; then
    printf '[pixi-bootstrap] global tool manifest not found: %s\n' "$manifest_path" >&2
    return 1
  fi

  if ! pixi_cmd="$(command -v pixi 2>/dev/null)"; then
    printf '[pixi-bootstrap] ERROR: pixi not found — cannot install global tools\n' >&2
    return 1
  fi

  # Detect current platform
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) platform="win-64" ;;
    Darwin)
      case "$(uname -m 2>/dev/null || true)" in
        aarch64|arm64) platform="osx-arm64" ;;
        *) platform="osx-64" ;;
      esac
      ;;
    Linux*) platform="linux-64" ;;
    *)
      printf '[pixi-bootstrap] ERROR: cannot detect platform\n' >&2
      return 1
      ;;
  esac

  printf '[pixi-bootstrap] installing global tools for %s\n' "$platform" >&2

  # Parse conda packages from the inline dependencies table inside [envs.default].
  local packages=""
  local in_default_env=false
  local in_dependencies_table=false

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^\[([a-zA-Z0-9._-]+)\]$ ]]; then
      local section="${BASH_REMATCH[1]}"
      in_default_env=false
      in_dependencies_table=false
      [[ "$section" == "envs.default" ]] && in_default_env=true
      continue
    fi

    if [[ "$in_default_env" == true && "$line" =~ ^[[:space:]]*dependencies[[:space:]]*=[[:space:]]*\{[[:space:]]*$ ]]; then
      in_dependencies_table=true
      continue
    fi

    [[ "$in_dependencies_table" == false ]] && continue

    if [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
      in_dependencies_table=false
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_-]+)[[:space:]]*= ]]; then
      local pkg_name="${BASH_REMATCH[1]}"
      if [[ "$packages" != *"$pkg_name"* ]]; then
        packages="${packages} ${pkg_name}"
      fi
    fi
  done < "$manifest_path"

  packages="$(echo "$packages" | sed 's/^ //')"

  if [[ -z "$packages" ]]; then
    printf '[pixi-bootstrap] WARNING: no packages found in manifest\n' >&2
    return 0
  fi

  printf '[pixi-bootstrap] conda packages: %s\n' "$packages" >&2

  # Install all conda packages in one command
  if ! "$pixi_cmd" global install ${packages}; then
    printf '[pixi-bootstrap] WARNING: pixi global install failed — continuing\n' >&2
  fi

  # Parse pypi packages for this platform and install via pip
  local pypi_packages=""
  local in_target_pypi=false

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^\[target\.([^\]]+)\]$ ]]; then
      local section="${BASH_REMATCH[1]}"
      if [[ "$section" == "${platform}.pypi-dependencies" ]]; then
        in_target_pypi=true
      else
        in_target_pypi=false
      fi
      continue
    elif [[ "$line" =~ ^\[ ]]; then
      in_target_pypi=false
      continue
    fi

    [[ "$in_target_pypi" == false ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*[\"\'](.*)[\"\'] ]]; then
      local pkg_name="${BASH_REMATCH[1]}"
      if [[ "$pypi_packages" != *"$pkg_name"* ]]; then
        pypi_packages="${pypi_packages} ${pkg_name}"
      fi
    fi
  done < "$manifest_path"

  pypi_packages="$(echo "$pypi_packages" | sed 's/^ //')"

  if [[ -n "$pypi_packages" ]]; then
    printf '[pixi-bootstrap] pypi packages: %s\n' "$pypi_packages" >&2
    if command -v pip >/dev/null 2>&1; then
      if ! pip install ${pypi_packages}; then
        printf '[pixi-bootstrap] WARNING: pip install failed — continuing\n' >&2
      fi
    else
      printf '[pixi-bootstrap] WARNING: pip not found — skipping pypi packages\n' >&2
    fi
  fi

  printf '[pixi-bootstrap] global tools install complete\n' >&2
  return 0
}
