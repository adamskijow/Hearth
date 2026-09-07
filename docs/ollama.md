<!-- SPDX-License-Identifier: MIT -->
# Ollama setup with Hearth

Hearth supervises an existing Ollama installation. Managed mode launches and
restarts `ollama serve`; attached mode watches a server owned by Ollama.app or
another service manager.

Your apps still talk to Ollama directly:

```
http://127.0.0.1:11434
```

## Which mode should I use?

- **I use the official Ollama app:** use attached mode. Ollama.app owns the
  server; Hearth watches it and alerts if it stops answering.
- **I installed Ollama with Homebrew and I log into this Mac:** use the normal
  app or login agent in managed mode. Stop `brew services` first so Hearth is the
  only supervisor.
- **I need Ollama serving before anyone logs in:** use the root daemon in managed
  mode, and set `runnerUser` to a real non-root account before starting it.
- **I only need Hearth to watch a server started by another manager:** use
  attached mode.

## Homebrew Ollama

Use managed mode when Hearth should launch and restart `ollama serve` itself:

```json
{
  "runner": "ollama",
  "mode": "managed",
  "host": "127.0.0.1",
  "port": 11434
}
```

If `brew services` is already running Ollama, stop it first:

```sh
brew services stop ollama
```

Two managers will fight over the same runner. `hearth doctor` reports this case
and tells you which manager it found. On a fresh config, `hearth setup` switches
to attached mode automatically when it sees Ollama already managed by launchd and
answering on the configured port, clear evidence another supervisor owns a live
runner. A loaded but silent job stops setup with the `brew services`
commands to inspect or stop it, so a stale service cannot park Hearth in attached
mode watching nothing.

## Ollama.app attached mode

The official Ollama app starts its own background server. In that setup, use
attached mode so Hearth watches the server the app owns:

```json
{
  "runner": "ollama",
  "mode": "attached",
  "host": "127.0.0.1",
  "port": 11434
}
```

Attached mode probes readiness, reports status, sends alerts, and leaves process
control to Ollama.app.

To switch explicitly:

```sh
hearth mode attached
```

If you later want Hearth to own the runner instead, quit Ollama.app, stop any
other manager, run `hearth mode managed`, and then run `hearth doctor`.

## Deep probes

The default probe checks Ollama's lightweight `/api/version` endpoint. That proves
the HTTP server answers, but a model or GPU can still be wedged behind it. To
catch that, set `probeModel` to a small model you have already pulled:

```json
{
  "probeModel": "qwen2.5:0.5b"
}
```

Hearth then runs a one-token generation on a slower interval while that model is
resident. Scheduled probes avoid cold loads and leave residency to Ollama's
`OLLAMA_KEEP_ALIVE` policy.

If the inference check fails repeatedly but Hearth has not observed client
traffic through its optional metrics proxy, it alerts without restarting. A long
queued generation and a wedge are otherwise indistinguishable. For automatic
inference-wedge recovery, enable the metrics proxy and point clients at its port;
Hearth then defers checks while a client request is in flight. Ordinary process
crashes and shallow API wedges still recover without the proxy.

In Preferences, **Inference health** can discover installed models, put the
smallest reported model first, and run the one-token test before you save. The
free-form config remains available for headless setups.

Choose a model your workload keeps resident. Smaller models make the optional
setup test cheaper. List models with:

```sh
ollama list
```

## LAN and remote access

Keep Ollama on `127.0.0.1` for local apps. Remote clients should use a trusted
LAN, VPN, or authenticated private proxy. Ollama accepts unauthenticated requests;
see the [network guide](reverse-proxy.md).
