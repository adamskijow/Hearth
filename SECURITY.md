# Security Policy

## Supported versions

Security fixes land on the latest 1.x release line.

| Product/version | Supported |
|-----------------|-----------|
| Full Hearth 1.x | yes |
| Full Hearth < 1.0 | no |
| Hearth Monitor, all versions | no; retired September 7, 2026 |

Monitor artifacts remain available for historical reference. There are no
planned Monitor releases or routine support. Report vulnerabilities in shared
code through the private channel below so they can be assessed for full Hearth.

## Reporting a vulnerability

Please report security issues privately, not in a public issue.

Use GitHub's private reporting: open the repository's **Security** tab and choose
**Report a vulnerability** (this opens a private advisory visible only to the
maintainer). Include the version, your macOS version, and steps to reproduce.

You can expect an acknowledgement within a few days. Once a fix is available it
will ship in a new release and the advisory will be published with credit, unless
you prefer to stay anonymous.

## Security posture

Hearth's main security boundaries:

- **Apple frameworks only.** The Swift package has no third-party dependencies.
- **Signed and notarized releases.** Hardened Runtime is enabled. Full Hearth runs
  outside App Sandbox to supervise another process.
- **Private control endpoint.** Bearer tokens use constant-time comparison.
  Peer throttling and connection caps limit abuse. Bind to localhost or a VPN.
  `GET /` and `GET /healthz` expose the shell page and Hearth liveness; runner
  state stays behind authentication. Browser tokens live for one tab.
- **Guarded reboot escalation.** This opt-in root feature enforces a minimum
  interval, daily cap, and boot-time backstop.
- **Code-bound reboot helper.** The experimental helper checks executable path,
  Developer ID requirement, audit token, user ID, and rate limit for every request.
