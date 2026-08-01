# Security Policy

## Supported Versions

Security fixes are generally applied to the default branch and the latest release line.

## Reporting a Vulnerability

Please do not open public issues for security vulnerabilities.

Instead, report privately to one of the following:

- `github+githree@glazastyy.com`
- `hi@smaia.dev`
- `security@githree.org` (alias that forwards to both maintainers)

Include:

- affected component (backend/frontend/config/deployment)
- clear reproduction steps
- impact assessment
- suggested fix (if available)

## Response Process

The project aims to:

1. acknowledge reports quickly
2. reproduce and triage severity
3. prepare and validate a fix
4. publish a patch and disclosure notes

## Scope Notes for Githree

Relevant classes of issues include:

- credential handling regressions (SSH/HTTPS host credentials)
- archive/path handling vulnerabilities
- denial-of-service vectors in git operations
- unsafe markdown/html rendering behavior
- information leakage in logs/errors

## Security Hardening Tips

- Restrict outbound network access in production where possible.
- Do not store plaintext credentials in public config files.
- Prefer read-only filesystem mounts except for `/app/data`.
- Rotate any leaked credentials immediately.
