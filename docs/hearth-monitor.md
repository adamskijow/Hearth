<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor prototype

The retained Monitor source explores sandboxed, read-only health checks for
local AI runners and Apple's on-device language model. It does not own runner
processes or perform recovery.

`HearthMonitorCore` contains the monitoring policy. `HearthMonitor` supplies the
macOS app, network clients, Keychain storage, and Foundation Models integration.
The source and regression tests remain in the Swift package for reference.

- [Design notes](hearth-monitor-audits.md): health states, process boundaries,
  and data handling.
- [Development](development.md#monitor-prototype): optional local packaging and
  boundary checks.
- [Privacy](../PRIVACY.md#monitor-prototype): local storage and network behavior.

Current product work is covered by the [Hearth plan](product-plan.md).
