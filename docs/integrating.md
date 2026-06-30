<!-- SPDX-License-Identifier: MIT -->
# Integrating with Hearth

Hearth is an availability layer for a local LLM runner (Ollama, LM Studio, or
mlx_lm). If your app or agent depends on a local runner being up, you do **not**
integrate against Hearth's API. You depend on the **runner**, and let Hearth keep
the runner alive underneath you.

## The model

- **One runner**, for example Ollama on `127.0.0.1:11434`, shared by every local
  app on the machine.
- **One Hearth** keeping that runner alive. Do not run a Hearth per app. Hearth
  has a single-instance guard, so several apps can each ensure Hearth is running
  and it resolves to one supervisor (the rest stand by or bow out, they never
  fight).
- **Your app talks to the runner directly** (Ollama's `/api/...`, an OpenAI
  compatible `/v1/...`, etc.), exactly as if Hearth were not there.

## What your app should do

1. **Make sure Hearth is installed and running.** The simplest setup, which a
   person or an agent can run as-is:

   ```sh
   brew install --cask adamskijow/tap/hearth   # if not already installed
   hearth setup                                 # detect runner, install agent, wait for ready
   ```

   `hearth setup` is the one-shot path: it detects the runner, points the config at
   it, installs the login agent, and waits for the runner to come up. If you want
   just the agent step, `hearth install-agent` writes a per-user LaunchAgent
   (`~/Library/LaunchAgents/com.hearth.headless.plist`) that runs Hearth headless
   at login and keeps it alive. It needs no sudo, and it is safe to run even if
   Hearth is already set up or the menubar app is also running (the guard makes one
   instance stand by). Remove it with `hearth uninstall-agent`.

2. **Gate your startup on the runner being ready**, if order matters:

   ```sh
   hearth wait-ready && start-my-app
   ```

   `hearth wait-ready` blocks until the runner answers its readiness endpoint, then
   exits 0; on timeout it exits 1. Use `-t SECONDS` to change the timeout (default
   120). It probes the runner directly, so it works whether or not Hearth itself is
   running, as long as the runner is up. In a LaunchAgent, run it as a
   `ProgramArguments` preflight, or just `hearth wait-ready && exec my-app`.

3. **Degrade gracefully on a transient miss.** Even with Hearth, there is a brief
   window during a restart where the runner is down. Treat a failed request as
   retryable rather than fatal. Hearth keeps that window short; your app keeps it
   invisible.

4. **Optionally, read Hearth's own health.** If the control endpoint is enabled,
   `GET /healthz` (unauthenticated) returns `200` when Hearth is up, `GET /status`
   (with the bearer token) returns the phase, uptime, resident models, and metrics,
   and `GET /metrics` (with the token) exposes the same as a Prometheus text
   exposition for Grafana or Uptime Kuma. Useful for a dashboard, not required for
   normal operation.

## Do not

- **Do not run a second Hearth per app.** One shared Hearth supervises the one
  shared runner. The guard will stop the duplicate from fighting, but there is no
  reason to start it.
- **Do not ship your own copy of the LaunchAgent plist.** Use
  `hearth install-agent` so the path and config stay correct and there is one
  canonical job (`com.hearth.headless`) rather than per-app copies that drift and
  collide.
- **Do not reach into Hearth's config or process.** Point at the runner; let
  Hearth do its job.

## Example: Hob

[Hob](https://github.com/adamskijow/Hearth) (a morning-digest agent) depends on
Ollama. Its integration is exactly the model above: install Hearth, run
`hearth install-agent` so Ollama stays up, and Hob talks to Ollama on localhost.
If Ollama wedges, Hearth restarts it; Hob degrades gracefully during the gap and
its requests resume on their own.
