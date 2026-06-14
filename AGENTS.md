# AGENTS.md - kano-cpp-infra

## Role

`kano-cpp-infra` is the shared native C++ infrastructure repo for Kano command
line tools and agent skills. Keep it generic, reusable, and suitable for public
source distribution.

## Guardrails

- Preserve existing user changes. Inspect `git status --short` before editing.
- Do not commit secrets, tokens, private keys, machine-local paths, or internal
  hostnames.
- Do not hardcode developer user names, drive letters, Jenkins URLs, LAN
  endpoints, or release credentials.
- Keep consumer compatibility in mind. Changes here affect repos that mount this
  repo at `src/cpp/shared/infra`.
- Prefer existing scripts, CMake targets, and Pixi tasks over adding parallel
  mechanisms.
- Public-facing docs should explain concepts without relying on private context.

## Repository Layout

- `code/systems/` contains reusable infra modules.
- `code/apps/` contains infra-owned helper CLIs.
- `config/` contains shared build/test matrix data.
- `scripts/cmake/` contains CMake package integration.
- `scripts/lib/`, `scripts/platform/`, `scripts/stages/`, and
  `scripts/workflows/` contain reusable build, test, coverage, report, and PGO
  automation.

## C++ Module Pattern

When adding a reusable module:

1. Add `code/systems/kano_infra_<module>/public/...` headers.
2. Add `code/systems/kano_infra_<module>/private/...` implementation files.
3. Add that module's `CMakeLists.txt`.
4. Add the subdirectory and alias target in the root `CMakeLists.txt`.
5. Link the module into `KanoInfra::All` only if it is safe as a default
   dependency for consumers.
6. Update README target lists and any consumer-facing examples.

Use target names in the `KanoInfra::<name>` namespace. Keep include paths stable
once published.

## Validation

Use the smallest validation that proves the change:

```powershell
pixi run env-summary
pixi run build
pixi run quick-test
pixi run test-report
pixi run coverage-all
```

For script-only changes, also run the relevant shell or PowerShell syntax checks
when available. For public docs, check that examples do not expose private
configuration and still match the current CMake/Pixi contract.

## CI Credential Policy

Public consumers can read this repository directly. If a private consumer or
internal mirror still needs authenticated access, prefer the
`kanohorizonia-jenkins` GitHub App through Actions variables/secrets:

- `KANO_JENKINS_APP_CLIENT_ID`
- `KANO_JENKINS_APP_PRIVATE_KEY`

Scope generated installation tokens to only the repositories and permissions
needed for the job. Do not replace this with a broad personal access token unless
there is a documented temporary reason.

## Public Repository Metadata

- Keep `LICENSE`, `NOTICE.md`, `CONTRIBUTING.md`, and `SECURITY.md` aligned with
  README public-facing guidance.
- Do not remove third-party license notices from vendored files.
- If GitHub repository settings are changed, verify that the repository remains
  public, issues are enabled, and the license is detected as MIT after pushing
  license changes.
