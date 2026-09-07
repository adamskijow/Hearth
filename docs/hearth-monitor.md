<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor is retired

**Retired September 7, 2026.** Standalone Hearth Monitor is no longer under
active development or routine support. There are no planned Monitor releases,
new Apple-model features, or further App Store submissions.

Development is focused on [full Hearth](../README.md): runner supervision,
recovery, inference health, and setup. Full Hearth's attached monitoring mode
remains supported.

## Existing installations

The 0.2.0 beta can continue to run, but it will not receive planned updates.
Retirement does not remotely uninstall the app or delete local settings.
Historical source and [beta artifacts](https://github.com/adamskijow/Hearth/releases/tag/hearth-monitor-v0.2.0)
remain available for reference, not as the recommended installation.

Monitor release, App Store packaging, and upload scripts now exit with a
retirement notice. Local archive builds and regression tests remain available
as described in the [development guide](development.md#retired-monitor-source).

## Migration options

- **Ollama or MLX on an always-on Apple silicon Mac:** install full Hearth and
  configure managed mode for automatic process recovery.
- **Ollama.app, LM Studio, or another existing manager:** use full Hearth in
  attached mode. The existing manager retains ownership; Hearth monitors and
  alerts. Follow the [Ollama guide](ollama.md) and [configuration reference](configuration.md).
- **Viewing another full Hearth installation:** use its authenticated
  [browser status page](remote-control.md#browser-status-page) with a status-only
  token.
- **Apple on-device model checks:** full Hearth does not replace this retired
  Monitor feature.
- **Intel Macs:** full Hearth requires Apple silicon. There is no supported
  native replacement from this project for Monitor's Intel app.

Full Hearth uses separate configuration. Monitor targets, Keychain credentials,
and history are not imported automatically. Configure and verify the new setup
before removing Monitor. Avoid giving two managers ownership of the same runner.

## Remove Monitor

1. Remove configured runners and full Hearth connections in Monitor Settings
   to delete the app's associated Keychain credentials.
2. Disable **Open at Login**, then quit Hearth Monitor.
3. Move **Hearth Monitor.app** from Applications to the Trash.
4. To remove retained settings and history, delete its sandbox container:

   ```text
   ~/Library/Containers/com.hearth.HearthMonitor
   ```

If a local development sampling agent was installed, remove it with
`./scripts/install-dogfood-monitor-agent.sh --uninstall`.

Runner applications, models, and full Hearth have separate installations.
The [privacy policy](../PRIVACY.md#retired-hearth-monitor) documents the beta's
local data and network behavior.

## Historical documentation

The [0.2.0 tagged source](https://github.com/adamskijow/Hearth/tree/hearth-monitor-v0.2.0)
preserves the original implementation and release instructions. The current
[product plan](product-plan.md) covers full Hearth only.
