<!-- SPDX-License-Identifier: MIT -->
# Ollama setup with Hearth

Hearth does not replace Ollama and does not install models. It supervises an
Ollama setup on a Mac: in managed mode it launches and restarts `ollama serve`,
and in attached mode it watches a server owned by something else.

Your apps still talk to Ollama directly:

```
http://127.0.0.1:11434
```

Hearth runs beside it as the supervisor.

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
runner. A loaded job that is not serving stops setup with the `brew services`
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

Attached mode does not spawn or kill Ollama. It keeps the Mac awake while
supervision is running, probes readiness, reports status, and notifies you when
the app-owned server stops answering.

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

Hearth then runs a one-token generation on a slower interval. It does not set
`keep_alive`, so Ollama's own `OLLAMA_KEEP_ALIVE` policy controls how long the
model remains resident.

Good probe models are small, already pulled, and cheap to load. You can list
models with:

```sh
ollama list
```

## LAN and remote access

Keep Ollama on `127.0.0.1` for local apps. To reach it from another machine, bind
only on a trusted LAN or put it behind a private reverse proxy. Ollama itself does
not authenticate requests. See [reverse-proxy.md](reverse-proxy.md) for the safe
pattern.

## Listing blurb

For a future community directory entry, Hearth can be described without changing
its scope:

> Hearth is a macOS menubar and CLI supervisor that keeps an existing Ollama
> server alive on headless Macs, with readiness probes, process-group restart
> recovery, sleep prevention, notifications, and Prometheus-style status.

This repository work does not create or submit any external pull request.
