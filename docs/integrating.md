<!-- SPDX-License-Identifier: MIT -->
# Integrating with Hearth

Apps talk to the local AI runner directly. Hearth keeps that shared runner
available underneath them.

## Recommended setup

1. Install and configure one Hearth instance per runner:

   ```sh
   brew install --cask adamskijow/tap/hearth
   hearth setup
   ```

   `hearth setup` detects the runner, writes the config, installs the per-user
   login agent, and waits for readiness. `hearth install-agent` and `hearth
   uninstall-agent` manage only the login agent.

2. Gate dependent startup when order matters:

   ```sh
   hearth wait-ready -t 120 && exec start-my-app
   ```

   The command probes the runner's shallow API readiness endpoint and returns
   `0` on readiness or `1` on timeout. It does not verify model generation.

3. Use bounded retries for requests safe to repeat during the restart window.
   Runner recovery does not resume an interrupted application job automatically.

4. Use Hearth's status surfaces for operations. With the control endpoint
   enabled, `/healthz` reports Hearth liveness, while authenticated `/status` and
   `/metrics` report runner state.

## Ownership rules

- Share one runner and one Hearth instance among local apps.
- Install the canonical login agent through `hearth install-agent`.
- Treat Hearth's config and process as operator-owned state.
- Send inference traffic to the runner, or to Hearth's metrics proxy when
  throughput and in-flight visibility are enabled.

The single-instance guard prevents duplicate supervisors from fighting, but a
single owner keeps startup and logs clear.

## Webhook automation

Webhook notifications contain `level`, `title`, `body`, `event`, and `timestamp`.
`event` is a stable snake-case kind such as `down`, `recovered`, `failing`,
`memory_limit_exceeded`, or `warmup_finished`. Home Assistant, n8n, and similar
tools can route these events directly.

See [Remote control and status](remote-control.md) for endpoints and
[Stability](stability.md) for the machine-readable contract.
