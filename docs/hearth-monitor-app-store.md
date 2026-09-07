<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor App Store work is retired

Standalone Hearth Monitor was retired on September 7, 2026. There are no further
App Store submissions, TestFlight uploads, or Store release milestones.

`scripts/package-monitor-app-store.sh` and
`scripts/upload-monitor-app-store.sh` exit immediately with a retirement notice.
Developer ID publication through `scripts/release-monitor.sh` is also disabled.

See [retirement and migration](hearth-monitor.md) for existing installations.
The [0.2.0 tagged checklist](https://github.com/adamskijow/Hearth/blob/hearth-monitor-v0.2.0/docs/hearth-monitor-app-store.md)
is retained as historical evidence, not a current release procedure.

Full Hearth continues to use Developer ID distribution; its
[release procedure](development.md#full-hearth-release) remains active.
