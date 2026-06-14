# Security Policy

## Reporting a vulnerability

Do not report suspected vulnerabilities by posting secrets, exploit details, or
private environment data in public issues.

For now, report security concerns privately to the repository owner or through a
private GitHub security advisory when available. Include:

- affected commit or release;
- affected platform;
- minimal reproduction steps;
- expected impact;
- whether secrets, tokens, or private infrastructure details were exposed.

## Supported versions

This repository is pre-1.0. The `main` branch is the supported development line.

## Secret-handling expectations

This repository must remain safe for public source distribution:

- no committed credentials, tokens, private keys, or service account material;
- no machine-local user profiles, private hostnames, LAN endpoints, or release
  credentials in public defaults;
- credentials must be injected by the caller's CI or local environment;
- generated reports, build outputs, coverage data, and package artifacts should
  stay out of source control unless explicitly documented as source fixtures.
