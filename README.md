# kano-cpp-infra

Shared native C++ infrastructure for Kano command line tools and agent skills.

This repository provides reusable CMake targets, platform helpers, process
utilities, diagnostics, timing helpers, and build/test/report scripts used by
Kano native projects. It is intended to be safe to consume from public projects:
do not put secrets, machine-local paths, private hostnames, or release-only
credentials in this repository.

## Repository Status

`KanoInfra::scheduler` exposes `kano::scheduler::Invoke` through the Windows
`kano_task_scheduler.exe` helper. Potentially blocking COM calls run in the
existing contained `Session` with finite operation/capture/cleanup budgets.
Timed-out mutations require readback before retry. Registration never replaces
an existing task; mutations compare the supplied task projection first. The
consumer retains task policy and resident lifecycle ownership.
The identity response includes the process `integrity_rid`. A failed root read
includes Low-integrity context when applicable, while preserving the actual
HRESULT. An inherited Low label on an executable can lower its child process
even when launched by a normal Medium user. Qualification should use the
authorized build context; this helper never changes tokens or ACLs.

`kano_local_path.hpp` validates absolute local paths and existing non-reparse
ancestry. `kano::process::QueryParent` brackets a read-only Windows parent
snapshot with exact child identity checks. No credentials, ACL changes or new
process containment implementation are introduced.

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
- `KanoInfra::scheduler` (opt-in Windows Task Scheduler helper transport)
- `KanoInfra::self`
- `KanoInfra::timing`
- `KanoInfra::unattended`

## Loopback listener snapshots

`kano_process_listener.hpp` provides finite read-only loopback listener
snapshots using Windows TCP owner tables or existing macOS `lsof` inside
`Session`. It permits exactly one literal IPv4 loopback listener. Consumers
bracket snapshots with contained child identity/lifecycle checks; a PID alone
never authorizes a stop. Missing tools, unsupported platforms or ambiguous
observations fail closed without process-discovery/termination fallback.
KINF-TSK-0180 exercises this helper through a compiled controlled engine.

## Bounded HTTP

Set `KANO_INFRA_ENABLE_HTTP=ON` before `add_subdirectory` to enable
`KanoInfra::http` and `kano_http.hpp`. This optional target reuses the consumer's
existing CURL 8 package; it is excluded from `KanoInfra::All`. Installed packages
with this option resolve CURL and expose the `http` component.

`kano::http::Perform` makes one direct GET or POST with finite transfer and body
budgets. It disables proxy, redirect, netrc and retry behavior, verifies TLS peer
and host, and supports cooperative connection cancellation. Errors contain a
fixed safe message and the received HTTP status when available, including body
overflow; no URL, bearer or response bytes appear in exceptions.

`LoopbackHttp` requires an explicit loopback HTTP port. `PrivateControl` also
permits literal RFC1918 or ULA addresses over verified HTTPS. Hostnames other
than normalized localhost, credentials in URLs, public addresses, fragments and
non-root endpoint paths are rejected. Consumers own credentials, protocol
validation, acknowledgement reconciliation and backend cancellation policy.
KINF-TSK-0179 exercises real loopback requests, bounded failures, read-only
commands and lost acknowledgements through Catch2 on the consuming CLI.

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

### Persistent contained child sessions

`KanoInfra::process` also exports the C++17 `<kano_process_session.hpp>` facade for a resident
child protocol. `kano::process::Session` has no lifetime timer. `Start`, `Write`,
`Poll`, and `Stop` use separate monotonic operation budgets. The caller owns
readiness, request framing, graceful shutdown, and request deadlines. `Poll`
returns incremental binary-safe chunks; `Write` can also return chunks drained
while input is blocked. Both streams have independent per-operation retention
limits and continue draining after truncation. Protocol consumers must reject
truncated protocol output. Environment inheritance is enabled by default; an
empty override removes an inherited key. Set `SessionOptions::inherit_environment`
to `false` for an empty starting environment with exact supplied values, including
present empty values. Both modes affect only the launched child and also apply
to Windows `LaunchDetached`. POSIX Session launch prepares an
explicit environment and absolute UTF-8 executable before `fork`; it never
changes the parent's environment. POSIX capture pipes use close-on-exec and
nonblocking parent I/O. The child owns a new process group. `Poll` observes exit
without reaping; `Stop` signals that owned group before reaping the root and
requires capture EOF within its cleanup budget. Escaped writers or lost child
ownership leave cleanup unverified. A host that auto-reaps children is refused.

On Windows, launch reuses the strict process foundation: the suspended child
cannot execute until assignment to a kill-on-close Job succeeds. Only its three
standard I/O handles are inherited. Closing or abruptly losing the owner kills
the contained descendants. `Stop` kills only that owned Job and confirms the
root, observed members, capture writers, and pending input cancellation have
finished before reporting `cleanup_complete`. Unconfirmed cleanup is failure;
the caller must preserve its ownership record. A failed launch with unconfirmed
cleanup leaves the Session permanently unverified: later empty `Stop`/`Close`
cannot claim success, and `Start` refuses reuse. The destructor makes a bounded
cleanup attempt and then closes owned handles. Kernel launch/cancellation and
host scheduling can overrun budgets. An OS cancellation that never completes
retains at most one 64 KiB input buffer/event to prevent use-after-free and is
reported as incomplete cleanup.

`Identity` records PID, creation token, and executable image. `QueryIdentity`,
`CurrentIdentity`, and `IsAlive` validate exact live identities without offering
a kill-by-PID operation. `LaunchDetached` starts an independent immediate child
without inherited handles or a new per-launch Job; it survives its immediate
caller's exit and retains any OS-imposed ancestor Job boundary. The detached
program must own its own workers. These additive APIs currently support
Windows only and return explicit unsupported errors elsewhere. Existing
cross-platform one-shot process APIs are unchanged.

Windows and POSIX Session support is separate from the Windows-only identity
and detached-launch APIs above. Linux has an actual controlled-child gate;
macOS execution must be qualified by each consumer.

The focused `infra.process_session` test covers protocol I/O, EOF, blocked
input, noisy stderr, failed launch/containment, exact identity, owned descendant
cleanup, abrupt owner death, and detached caller exit. Consumers may set
`KANO_PROCESS_SESSION_TEST_LABELS` before adding `code/tests/process_session`
to include this contract in a focused gate.

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
