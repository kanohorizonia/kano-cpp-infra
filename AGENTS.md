# AGENTS.md — kano-cpp-infra

## Role

`kano-cpp-infra` is a **code repo** (not a documentation-only skill). It provides reusable native runtime code to consuming Kano skills.

## Ownership

- **Owner**: Kano platform team
- **Mount path**: `src/shared/infra` in all Phase 1 consuming repos
- **Non-product-ownership caveat**: `kano-cpp-infra` is shared infrastructure, not product-owned source. Consuming repos do not modify infra directly; changes go through the infra repo.

## Version Policy

- **Pinning**: consuming repos pin to a specific `KANO_INFRA_VERSION` tag (e.g. `v1.0.0`)
- **Update owner**: platform team lead approves infra version bumps
- **Validation step**: after updating infra, CI must pass full build + test suite before merge
- **Rollback**: `git submodule deinit src/shared/infra` reverts to previous pinned revision
- **Compatibility matrix**: repo × infra version × toolchain documented in consuming repo's `docs/`

## Deprecation

- 90-day notice before removal
- During deprecation: consumer must upgrade or pin frozen version

## Adding New Modules

1. Add `PUBLIC/<module>/kano_<module>.h` with C facade
2. Add `PRIVATE/<module>/<module>_impl.cpp` with implementation
3. Add `kano_infra_<module>` INTERFACE library target in `CMakeLists.txt`
4. Add `KanoInfra::<module>` alias
5. Update this `AGENTS.md` module inventory

## CI

- CMake build test on Windows (MSVC), Linux (GCC/Clang), macOS (Clang)
- Header self-containment check (every PUBLIC header compiles standalone)
