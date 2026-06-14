# Contributing

Thanks for helping improve `kano-cpp-infra`.

## Development workflow

Use the smallest validation that proves the change:

```powershell
pixi run env-summary
pixi run build
pixi run quick-test
```

For broader changes, also run:

```powershell
pixi run test-report
pixi run coverage-all
```

## Repository expectations

- Keep this repository generic and reusable for Kano native C++ projects.
- Do not commit secrets, tokens, private keys, local credential files, private
  hostnames, or machine-local paths.
- Preserve public CMake target names once consumers depend on them.
- Prefer additive modules and compatibility-preserving changes.
- Keep public documentation accurate for Windows, Linux, and macOS.
- Use existing Pixi, CMake, and script entrypoints instead of adding parallel
  build systems.

## Pull requests

Before opening a pull request:

- describe the change and affected public targets;
- list validation commands and results;
- call out compatibility risks for consumers that mount this repository at
  `src/cpp/shared/infra`;
- include migration notes when a public target, include path, script, or Pixi
  task changes.
