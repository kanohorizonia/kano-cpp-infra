# `kano-cpp-infra`

Shared native runtime library for Kano C++ skills.

## Module Inventory

| Module | Responsibility | Non-goals |
|---|---|---|
| `config` | layered TOML config loading, effective config merge, path discovery | not a schema validator, not a CLI argument parser |
| `build_info` | app version, build metadata, VCS revision | not a package manager, not a build orchestrator |
| `platform` | OS detection, path normalization, env helpers | not a filesystem abstraction, not a shell emulator |
| `process` | subprocess spawn, stdout/stderr capture, exit code | not a job scheduler, not a log aggregator |
| `diagnostics` | structured error reporting, error code taxonomy, diagnostic output formatting | not a log aggregation system, not a crash reporter |
| `self` | self-build/rebuild metadata, bootstrap sequencing, internal dependency graph | not a package installer, not a general-purpose task runner |

## Consumption

```cmake
# In consuming product CMakeLists.txt:
add_subdirectory(src/shared/infra KanoInfra)
target_link_libraries(my_app PUBLIC KanoInfra::config KanoInfra::build_info)
```

Or via `find_package`:

```cmake
find_package(KanoInfra REQUIRED)
target_link_libraries(my_app PUBLIC KanoInfra::All)
```

## Public API Boundary

- All headers are in `PUBLIC/` and are linkable from consuming products.
- `PRIVATE/` internals may change without notice; products must not depend on them.

## Principles

- **Build-time vs run-time**: build 時用 subst、跑時用原本的路徑
- **Platform convention**: Linux ARM64 and macOS ARM64 slugs supported
- **Submodule mount path**: `src/shared/infra` (not `externals/`, not `vendor/`)
- **Version**: `KANO_INFRA_VERSION` defined in `CMakeLists.txt`
