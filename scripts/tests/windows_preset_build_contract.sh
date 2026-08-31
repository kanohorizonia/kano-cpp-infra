#!/usr/bin/env bash
# KOG_CONTRACT_TEST: Windows preset wrapper does not replay failed actions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(cygpath -u "$(mktemp -d /tmp/kano-windows-wrapper-contract.XXXXXX)")"
FAKE_BIN="$TEST_ROOT/bin"
CALL_LOG="$TEST_ROOT/calls.log"
mkdir -p "$FAKE_BIN"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

cat >"$FAKE_BIN/powershell" <<'FAKE_POWERSHELL'
#!/usr/bin/env bash
set -euo pipefail

mode="unknown"
action=""
previous=""
for argument in "$@"; do
  if [[ "$argument" == "-File" ]]; then
    mode="file"
  elif [[ "$argument" == "-Command" ]]; then
    mode="command"
  elif [[ "$previous" == "-Action" ]]; then
    action="$argument"
  fi
  previous="$argument"
done

printf '%s:%s\n' "$mode" "$action" >>"$KANO_WINDOWS_WRAPPER_CALL_LOG"
if [[ "$action" == "probe" ]]; then
  exit 0
fi
if [[ "$action" == "fail-action" || "$mode" == "command" ]]; then
  exit 23
fi
exit 0
FAKE_POWERSHELL
chmod +x "$FAKE_BIN/powershell"

export KANO_WINDOWS_WRAPPER_CALL_LOG="$CALL_LOG"
export PATH="$FAKE_BIN:$PATH"
hash -r

# Keep wrapper bootstrap from replacing the controlled test PATH.
cmake() { :; }
ninja() { :; }

# shellcheck source=../lib/windows_preset_build.sh
source "$REPO_ROOT/scripts/lib/windows_preset_build.sh"
KANO_WINDOWS_PS_HELPER_MODE=""

set +e
kano_windows_run_ps_helper -Action fail-action
status=$?
set -e

if [[ "$status" -ne 23 ]]; then
  echo "Expected failed helper action to preserve exit code 23, got $status." >&2
  exit 1
fi

probe_count="$(grep -c '^file:probe$' "$CALL_LOG" || true)"
action_count="$(grep -c '^file:fail-action$' "$CALL_LOG" || true)"
fallback_count="$(grep -c '^command:' "$CALL_LOG" || true)"
if [[ "$probe_count" -ne 1 || "$action_count" -ne 1 || "$fallback_count" -ne 0 ]]; then
  echo "Expected one probe and one failed action without fallback replay." >&2
  cat "$CALL_LOG" >&2
  exit 1
fi

PRESET_ARGS_LOG="$TEST_ROOT/preset-args.log"
kano_windows_detect_vcvarsall() { printf '%s\n' 'C:/fake/vcvarsall.bat'; }
kano_windows_file_exists() { return 0; }
kano_windows_apply_self_build_config() { :; }
kano_windows_collect_build_metadata() { :; }
kano_cpp_print_self_build_toolchain() { :; }
kano_windows_native_root() { printf '%s\n' 'C:/physical/source/src/cpp'; }
kano_windows_prepare_subst_root() { printf 'Z:/\tZ:\t1\n'; }
kano_windows_cleanup_subst_drive() { :; }
kano_windows_run_ps_helper() {
  printf '%s\n' "$@" >"$PRESET_ARGS_LOG"
}

export KANO_WINDOWS_BUILD_TARGET="kog_runtime_artifact"
kano_windows_run_preset windows-ninja-msvc windows-ninja-msvc-release x64

root_argument="$(awk '/^-Root$/{getline; print; exit}' "$PRESET_ARGS_LOG")"
canonical_argument="$(awk '/^-CanonicalRoot$/{getline; print; exit}' "$PRESET_ARGS_LOG")"
target_argument="$(awk '/^-BuildTarget$/{getline; print; exit}' "$PRESET_ARGS_LOG")"
if [[ "$root_argument" != "Z:/" ]]; then
  echo "Expected the preset action to use the shortened build root, got '$root_argument'." >&2
  cat "$PRESET_ARGS_LOG" >&2
  exit 1
fi
if [[ "$canonical_argument" != "C:/physical/source/src/cpp" ]]; then
  echo "Expected the preset action to preserve the physical source root, got '$canonical_argument'." >&2
  cat "$PRESET_ARGS_LOG" >&2
  exit 1
fi
if [[ "$target_argument" != "kog_runtime_artifact" ]]; then
  echo "Expected the preset action to preserve the requested build target, got '$target_argument'." >&2
  cat "$PRESET_ARGS_LOG" >&2
  exit 1
fi

echo "PASS: Windows preset wrapper executes each action once and preserves the physical source root"
