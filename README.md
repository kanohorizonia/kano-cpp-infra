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
    kano_infra_unattended/
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
- `KanoInfra::unattended`

## Unattended Native Execution

The header-only `KanoInfra::unattended` target supplies `kano_unattended.hpp`.
Call `kano::infra::ConfigureUnattendedExecution()` first in each native test
`main()`, before threads or test discovery. The policy executes in the caller's
CRT, including an independently linked `/MT` DLL that calls it at its own
startup boundary. Linking a target, including a header, or linking
`KanoInfra::All` does not activate it.

Product CLI startup should call
`kano::infra::ConfigureUnattendedExecutionIfRequested()`. A nonempty
`KANO_UNATTENDED` selects the mode; `0`, `false`, `no`, or `off` explicitly keeps
human debugging. When that variable is absent or empty, nonempty, enabled
`KANO_AGENT_MODE` or `CI` activates the policy. Tests activate it explicitly and
do not inherit the human opt-out.

Windows startup preserves existing error-mode bits, sends CRT errors to stderr,
disables process-local abort reporting UI, and terminates on invalid CRT
parameters and fatal narrow/wide Debug reports. Native exception and abort
handlers emit a diagnostic and terminate the process without DLL shutdown
callbacks. POSIX startup disables this process's core files while preserving
fatal signal behavior. This policy does not cover errors before startup, another
DLL's CRT without activation, vendor dialogs, or a debugger intercepting faults.
It does not change global WER, registry, debugger, or service settings.

Consumers needing only startup policy can avoid the full library dependencies:

```cmake
include(src/cpp/shared/infra/scripts/cmake/KanoInfraUnattended.cmake)
target_link_libraries(my_app PRIVATE KanoInfra::unattended)
```

After all test registrations, call `kano_infra_finalize_test_timeouts(300)`.
Missing deadlines receive that positive default; explicit empty, zero, negative,
non-finite, generator-expression, or values exceeding 2147483647 seconds fail
configuration. Traversing child
test directories requires CMake 3.28. Earlier consumers can call
`kano_infra_finalize_local_test_timeouts(300)` in each test directory. Tests
discovered at build/run time need registration properties:

```cmake
kano_infra_test_properties(test_properties 300)
catch_discover_tests(my_tests PROPERTIES ${test_properties})
```

CTest per-test timeouts do not bound configure/build/coverage or the entire
suite. Use the strict owned-process runner with a positive whole-job deadline
and a separate cleanup allowance for every unattended command. Resident service
lifetime is outside that bounded-command contract.

Shared wrappers and the native watchdog route `TEMP`, `TMP`, and `TMPDIR` to a
unique `<cpp-root>/out/tmp/unattended/job-*` directory. Set
`KANO_UNATTENDED_TEMP_ROOT` to choose another owned root. Nested stages inherit
the same directory, and the caller environment is restored after an executable
wrapper returns. This keeps MSVC `/Zi` temporary-file writes inside the workspace
when system temp access is unavailable under process containment. The workflow
keeps its temp directory for diagnostics and never removes unrelated temp paths.
Explicit `KANO_UNATTENDED=0` preserves human debugging in shared wrappers; owned
test mains continue to apply their always-active unattended guard.

The independent fixture project runs without JsonCpp or network downloads:

```powershell
cmake -S code/tests -B build/unattended -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/unattended
ctest --test-dir build/unattended --output-on-failure
```

Run those commands through the whole-job watchdog in agent/CI validation. MSVC
fixtures cover `/MD`, `/MDd`, `/MT`, and `/MTd`, always-active Release checks,
assertions, aborts, native crashes, invalid parameters, narrow/wide reports, and
the independent DLL CRT. The parent harness requires expected status, diagnostic,
nonzero failure, positive deadlines, containment, and completed cleanup. Each
consumer still requires its own startup/adoption verification on supported hosts.

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
