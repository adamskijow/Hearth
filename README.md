<p align="center">
  <img src="assets/hearth-banner.svg" alt="Hearth: keeps your local LLM runner alive and serving" width="100%">
</p>

# Hearth

<p align="center">
  <a href="https://github.com/adamskijow/Hearth/actions/workflows/ci.yml"><img src="https://github.com/adamskijow/Hearth/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/adamskijow/Hearth/releases/latest"><img src="https://img.shields.io/github/v/release/adamskijow/Hearth?sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/adamskijow/Hearth" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple&logoColor=white" alt="macOS 14+">
</p>

**Keep Ollama alive on an always-on Mac.** Hearth is a small macOS supervisor that
restarts your local model runner when it crashes and, unlike `launchd` or `brew
services`, also when it is still running but has quietly stopped answering, often
after a GPU hang. It keeps the Mac awake while serving and alerts you, including on
your phone, when something breaks. LM Studio and mlx_lm work alongside Ollama.

Built for any Apple Silicon Mac that serves models unattended: a Mac mini in a
closet, a home-lab server, or a desktop left on overnight. Your apps keep talking to
the runner exactly as before. *Independent project, not affiliated with Ollama.*

<p align="center">
  <img src="assets/wedge-recovery.gif" alt="Hearth catching a runner that is still running but stuck, and recovering it hands-off" width="820">
</p>

<p align="center"><em>Catching a runner that is still running but stuck (not answering), and recovering it on its own (<code>make demo</code>).</em></p>

## Why

`launchd` and `brew services` relaunch a runner that has *exited*. They cannot see
the failure that actually strands you: a runner still running but no longer
answering, like a [GPU hang](https://community.frame.work/t/ollama-model-runner-unexpectedly-stopped-gpu-hang/76220),
a [silent revert to CPU](https://github.com/ollama/ollama/issues/8594), or a
[hang after a few requests](https://github.com/ollama/ollama/issues/6616). Hearth
checks **readiness** (does the API answer?), not just **liveness** (is the PID
alive?), so it catches the wedge, not just the crash. And it stays native instead of
putting Ollama in Docker, which on macOS is
[CPU-only](https://github.com/ollama/ollama/blob/main/docs/faq.mdx#how-do-i-use-ollama-with-gpu-acceleration-in-docker)
and throws away the Metal GPU. The full story, with a live GPU-crash recovery, is in
[How it works](docs/how-it-works.md).

## Getting started

If you already run Ollama on this Mac:

```
brew install --cask adamskijow/tap/hearth
open /Applications/Hearth.app
```

A flame appears in the menubar; Hearth auto-detects Ollama, starts supervising it,
and keeps the Mac awake. **It is working when** the flame has no warning badge and
the menu says **Healthy**. From a terminal, `hearth doctor` checks your setup and
`hearth status` shows health, uptime, and loaded models.

- **Homebrew Ollama:** run `brew services stop ollama` first so it does not fight
  Hearth over the runner, then let Hearth manage it.
- **Ollama.app:** it starts its own server, so have Hearth watch that one (attached
  mode); Hearth offers this as a one-click switch when it sees the collision.

To remove: `brew uninstall --cask hearth` (add `--zap` to delete config and logs
too). Ollama is untouched.

## Configure

Set options in **Preferences** (Cmd-comma) or `~/Library/Application Support/Hearth/config.json`;
changes apply **without a restart**. The keys most people touch are `runner`/`mode`,
the binary path and `host`/`port`, `ntfyTopic` for phone alerts, and
`controlEnabled`/`controlToken` for the [control endpoint](docs/remote-control.md).

**managed** mode means Hearth starts and restarts the runner; **attached** means
something else starts it and Hearth only watches. Switch with `hearth mode managed` /
`hearth mode attached`, or let `hearth setup` pick for a clean install. Every key,
with a full example, is in the [configuration reference](docs/configuration.md).

## Security

Hearth runs unsandboxed (supervising another process is exactly what the App Sandbox
forbids) as a Developer ID signed and notarized build, and sends only short status
text to notifiers, never prompts or model content. The runner stays on `127.0.0.1`
by default; do not expose it raw, since it has no authentication of its own. Exposure
and reverse-proxy setup are in the [reverse-proxy guide](docs/reverse-proxy.md).

## Docs and links

- **[Keeping Ollama running on macOS](docs/keep-ollama-running-on-macos.md)**: why it stops responding, what to try, and where Hearth fits
- **[FAQ](docs/faq.md)** and **[Troubleshooting](docs/troubleshooting.md)**: is Hearth for you, which mode, and the common fixes
- **[How it works](docs/how-it-works.md)**: the wedge problem, the evidence, and the mechanism
- **[Configuration](docs/configuration.md)**: every config key and default
- **[Ollama setup](docs/ollama.md)**, **[Remote control](docs/remote-control.md)**, **[Running headless](docs/running-headless.md)**
- **[Integrating](docs/integrating.md)**, **[Reverse proxy](docs/reverse-proxy.md)**, **[Stability](docs/stability.md)**, **[Limitations](docs/limitations.md)**, **[Development](docs/development.md)**

Contributions are welcome: run `make test` before sending a change, and see the
[development guide](docs/development.md). Released under the MIT License; see
[LICENSE](LICENSE). No third-party dependencies.
