# Security Policy

## Supported versions

Security fixes land on the latest 1.x release line.

| Version | Supported |
|---------|-----------|
| 1.x     | yes       |
| < 1.0   | no        |

## Reporting a vulnerability

Please report security issues privately, not in a public issue.

Use GitHub's private reporting: open the repository's **Security** tab and choose
**Report a vulnerability** (this opens a private advisory visible only to the
maintainer). Include the version, your macOS version, and steps to reproduce.

You can expect an acknowledgement within a few days. Once a fix is available it
will ship in a new release and the advisory will be published with credit, unless
you prefer to stay anonymous.

## Security posture

A few things worth knowing when assessing Hearth:

- **No third-party dependencies.** Hearth builds against Apple system frameworks
  only, so the supply-chain surface is effectively empty.
- **Signed and notarized.** Releases are Developer ID signed with the Hardened
  Runtime enabled and notarized by Apple. The App Sandbox is intentionally off,
  because supervising another process is incompatible with the sandbox.
- **The control endpoint is a control surface, not a public API.** It refuses to
  start without a bearer token, compares the token in constant time, and should be
  bound to localhost or a private interface (a Tailscale address is ideal), never
  a public one. `GET /` and `GET /healthz` are intentionally unauthenticated and
  reveal nothing about the runner.
- **Reboot escalation runs as root and can reboot the Mac.** It is opt-in and off
  by default, and only takes effect when Hearth runs as the headless
  LaunchDaemon. When enabled it is guarded against reboot loops by a minimum
  interval, a daily cap, and a kernel boot-time backstop. Review
  `RebootEscalation` before enabling it.
