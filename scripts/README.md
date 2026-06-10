# Shell Script Taxonomy — Infra Scripts

## Purpose

This directory (`scripts/`) follows a role-first taxonomy that makes file intent obvious
from location alone. Before moving or creating any file here, read this contract.

---

## Canonical Folder Roles

| Folder | Role | Executable? | Contents |
|--------|------|-------------|----------|
| `lib/` | Source-only shell libraries | **NO** | `.sh` files that are `source`d; never directly executed |
| `stages/` | Single-step entrypoints | **YES** | Executable shell scripts that perform one build/test/stage operation |
| `workflows/` | Multi-step orchestrators | **YES** | Executable shell scripts that coordinate multiple stages |
| `platform/` | Platform-specific wrappers | **YES** | Executable wrappers for Linux, macOS, Windows; map host OS → correct tool |
| `tools/` | Standalone utilities | **YES** | Independent native/shell/PowerShell tools that do not belong to a subsystem |
| `reports/` | Reporting subsystem | **YES** | Report generation, packaging, providers, and verification |

### Non-Shell Exceptions (out of taxonomy)

| Folder | Reason |
|--------|--------|
| `cmake/` | Non-shell CMake configuration. Never mixed with shell scripts. |

---

## Hard Rules

### ✅ DO

- All executable entrypoints live at `scripts/` root or in role folders (`stages/`, `workflows/`, `platform/`, `tools/`)
- Source-only libraries go in `lib/`
- Reporting tools go in `reports/`, with `providers/` (provider-specific adapters) and `verify/` (verification logic) subfolders
- Follow existing `stages/` and `workflows/` naming; they are already correct

### ❌ DO NOT

- **Never use `common/`** as a dumping ground for mixed-role files — it is deprecated
- **Never create dual-mode files** (files that work both as source library AND executable entrypoint)
  - Exception: existing dual-mode files (`coverage_report.sh`, `coverage_workflow.sh`, `pgo_workflow.sh`) are grandfathered but should be migrated to proper roles
- **Never mix wrappers with helper libraries** in `platform/` — wrappers only; helper libs go to `lib/`
- **Never mix non-shell content** into shell taxonomy (`cmake/` is the only approved exception)

---

## Approved Exceptions

1. **`cmake/`** — non-shell config, exempt from shell taxonomy rules
2. **`profiling/`** — self-contained subsystem (data + native tool calls + shell); treated as a single unit
3. **Existing dual-mode files** (`coverage_report.sh`, `coverage_workflow.sh`, `pgo_workflow.sh`) — grandfathered but targeted for migration

---

## Reports Subsystem Structure

```
reports/
  providers/     — Provider-specific adapters (llvm/, microsoft/, opencppcoverage/, windows/, linux/, macos/)
  verify/        — Verification logic for report content
  <renderers>    — Report rendering scripts/tools
  <packaging>    — Report packaging scripts
```

---

## Migration Status

- `src/cpp/scripts/` — **DEPRECATED** (empty, pending removal). All content moved to this directory.
- `lib/` — **TO BE CREATED** during migration; will receive source-only libs from `common/`
- Platform wrappers in `platform/` subfolders — wrappers only, no helper libs
- Dual-mode files (`coverage_report.sh`, `coverage_workflow.sh`, `pgo_workflow.sh`) — targeted for migration to `lib/` or proper entrypoint folders

---

## Adding a New File

1. **Is it directly executable** (called by CI, entrypoints, or humans)?
   - YES → Which operation? Single step → `stages/`. Multi-step → `workflows/`. Platform-specific → `platform/<os>/`. Standalone tool → `tools/`.
   - NO → It is a source library → `lib/`

2. **Does it belong to the reporting subsystem**?
   - YES → `reports/` with `providers/` or `verify/` subfolders

3. **Is it a non-shell config** (CMake, TOML, JSON data)?
   - YES → `cmake/` or appropriate non-shell location

---

## Naming Conventions

- Executable entrypoints: lowercase with dashes (`build.sh`, `coverage-report.sh`)
- Source libraries: lowercase with underscores (`build_helpers.sh`)
- No `*.lib.sh` suffix — folder semantics distinguish role

---

## Verification

```bash
# Check that no source library is accidentally executable
bash -n lib/*.sh

# Check that all entrypoints are actually executable
[ -x stages/*.sh ] && echo "OK" || echo "FAIL"

# Check no new common/ usage
grep -r "common/" scripts/ --include="*.sh" | grep -v "reports/common/"
```
