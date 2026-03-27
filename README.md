# `kano-cpp-infra`

Shared native runtime library for Kano C++ skills.

## Layout

```
code/
  apps/
  systems/
    kano_infra_build_info/
    kano_infra_config/
    kano_infra_diagnostics/
    kano_infra_platform/
    kano_infra_process/
    kano_infra_self/
  tests/
scripts/
  cmake/
```

## Consumption

```cmake
add_subdirectory(src/cpp/shared/infra KanoInfra)
target_link_libraries(my_app PUBLIC KanoInfra::config KanoInfra::build_info)
```

## Principles

- Build-time vs run-time: build uses subst, runtime uses real paths
- Platform convention: Linux ARM64 and macOS ARM64 slugs supported
- Submodule mount path: `src/cpp/shared/infra`
- Version: `KANO_INFRA_VERSION` defined in `CMakeLists.txt`
