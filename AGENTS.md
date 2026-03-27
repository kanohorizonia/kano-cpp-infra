# AGENTS.md - kano-cpp-infra

## Role

`kano-cpp-infra` is a code repo that provides reusable native runtime code to consuming Kano skills.

## Ownership

- Owner: Kano platform team
- Mount path: `src/cpp/shared/infra` in consuming repos
- Non-product-ownership caveat: consuming repos should update infra through the infra repo

## Layout

- `scripts/` contains build/config support such as CMake package files
- `code/systems/` contains reusable infra modules
- `code/apps/` and `code/tests/` are reserved for future aligned growth

## Adding New Modules

1. Add `code/systems/kano_infra_<module>/public/kano_<module>.h`
2. Add `code/systems/kano_infra_<module>/private/<module>_impl.cpp`
3. Add module `CMakeLists.txt` in that system directory
4. Update root `CMakeLists.txt` and this file
