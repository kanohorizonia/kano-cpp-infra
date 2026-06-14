# kano-cpp-infra

Shared native C++ infrastructure for Kano command line tools and agent skills.

This repository provides reusable CMake targets, platform helpers, process
utilities, diagnostics, timing helpers, and build/test/report scripts used by
Kano native projects. It is intended to be safe to consume from public projects:
do not put secrets, machine-local paths, private hostnames, or release-only
credentials in this repository.

## Repository Status

This repository is public and distributed under the MIT License. Documentation,
examples, scripts, and defaults must remain safe for public readers. Do not add
secrets, machine-local paths, private hostnames, or release-only credentials.

## Layout

```text
code/
  apps/
    kano_infra_tool/
  systems/
    kano_infra_build_info/
    kano_infra_config/
    kano_infra_diagnostics/
    kano_infra_platform/
    kano_infra_process/
    kano_infra_self/
    kano_infra_timing/
config/
  matrix.yml
scripts/
  cmake/
  lib/
  platform/
  stages/
  workflows/
```

## Consuming From Another Repo

The canonical mount path in consuming repos is:

```text
src/cpp/shared/infra
```

Add the repository as a submodule, then wire it into CMake:

```cmake
add_subdirectory(src/cpp/shared/infra KanoInfra)
target_link_libraries(my_app PRIVATE KanoInfra::All)
```

Use narrower targets when a consumer only needs part of the library:

```cmake
target_link_libraries(my_app PRIVATE
    KanoInfra::config
    KanoInfra::process
    KanoInfra::diagnostics
)
```

Public CMake targets currently include:

- `KanoInfra::All`
- `KanoInfra::build_info`
- `KanoInfra::config`
- `KanoInfra::diagnostics`
- `KanoInfra::platform`
- `KanoInfra::process`
- `KanoInfra::self`
- `KanoInfra::timing`

## Tooling

Kano projects use Pixi for repeatable developer tooling and CMake/Ninja for the
native build. The shared global tool manifest is:

```powershell
pixi global install -m .\pixi-global-tool.toml
```

Useful checks:

```powershell
pixi run env-summary
pixi run build
pixi run quick-test
pixi run test-report
pixi run coverage-all
```

From a consuming repository, run the shared manifest explicitly when the root
repo has its own Pixi manifest:

```powershell
pixi run --manifest-path src/cpp/shared/infra/pixi.toml env-summary
```

## CI And Dependency Access

Public consumers can read this repository directly through GitHub. If a private
consumer or internal mirror still needs authenticated access, use a GitHub App
installation token rather than a personal token.

For Kano-hosted GitHub Actions, the preferred app is `kanohorizonia-jenkins`.
Configure these Actions settings at the repository or organization level:

- Variable: `KANO_JENKINS_APP_CLIENT_ID`
- Secret: `KANO_JENKINS_APP_PRIVATE_KEY`

The workflow should scope any generated token to only the repositories and
permissions needed for the job, with `contents: read` unless write access is
explicitly required. Personal access tokens should only be kept as a temporary
fallback.

## Compatibility Policy

- Keep public targets stable once a consuming repo depends on them.
- Prefer additive modules over changing existing target names or include paths.
- Keep cross-platform behavior explicit for Windows, Linux, and macOS.
- Use portable scripts and avoid hardcoded user profiles, drive letters, host
  names, or internal service URLs.
- Treat generated reports and package manifests as build artifacts, not source.

## Security

Never commit secrets, private keys, tokens, local credential files, or service
account material. If a workflow needs credentials, document the expected
variable or secret name and let the CI platform inject it at runtime.

See `SECURITY.md` for vulnerability reporting and public-source safety rules.

## Contributing

See `CONTRIBUTING.md` for development workflow, validation expectations, and
compatibility notes for consumers.

## Notices

See `NOTICE.md` for third-party notices, including the vendored `toml.hpp`
license notice.

## License

MIT License. See `LICENSE`.
