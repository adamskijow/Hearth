<p align="center">
  <img src="assets/hearth-banner.svg" alt="Hearth: keeps your local LLM runner alive and serving" width="100%">
</p>

# Hearth

<p align="center">
  <a href="https://github.com/adamskijow/Hearth/actions/workflows/ci.yml"><img src="https://github.com/adamskijow/Hearth/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/adamskijow/Hearth/releases/latest"><img src="https://img.shields.io/github/v/release/adamskijow/Hearth?sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/adamskijow/Hearth" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20Apple%20silicon-black?logo=apple&logoColor=white" alt="macOS 14+ on Apple silicon">
</p>

**Keep local AI runners alive on an always-on Mac.** Hearth supervises Ollama,
LM Studio, `mlx_lm`, and Osaurus. It detects crashes and hung inference, preserves
native Metal GPU use, keeps the Mac awake, and sends failure alerts.

It suits an unattended Mac mini, home-lab server, or desktop left on overnight.
Apps continue using the runner's normal endpoint. Hearth is an independent
community project.

Hearth requires macOS 14 or later on Apple silicon.

<p align="center">
  <img src="assets/wedge-recovery.gif" alt="Hearth catching a runner that is still running but stuck, and recovering it hands-off" width="820">
</p>

<p align="center"><em>Detecting and recovering a hung runner (<code>make demo</code>).</em></p>

## Why

`launchd` and `brew services` relaunch exited processes. Hearth also checks API
readiness and can run a tiny generation probe, catching hangs that leave the
process alive. Recovery stays native, retaining Metal GPU acceleration. See
[how Hearth works](docs/how-it-works.md).

## Recovery coverage

Managed mode starts and restarts Ollama or `mlx_lm`. Attached mode watches a
runner owned by Ollama.app, LM Studio, or another manager and leaves process
control to that owner. Osaurus support is experimental; attached mode is
recommended.

Process exits and API failures recover automatically in managed mode. Inference
checks require a configured resident model. Automatic inference recovery also
requires client traffic through the metrics proxy. See [known
limitations](docs/limitations.md) for current traffic-visibility limits.

**Hearth Monitor was retired on September 7, 2026.** The separate sandboxed app
and its Apple-model checks are no longer under active development. Its source
and beta downloads remain historical archives. Full Hearth's attached mode
continues to be supported. See [retirement and migration](docs/hearth-monitor.md).

## Install full Hearth

If you already run Ollama on this Mac:

```sh
brew install --cask adamskijow/tap/hearth
open /Applications/Hearth.app
```

A flame appears in the menu bar. **Healthy** confirms that the runner answers.
`hearth doctor` checks setup; `hearth status` shows health, uptime, and models.

If you use Ollama.app or `brew services`, read the
[Ollama setup guide](docs/ollama.md) before choosing managed or attached mode.
Most options live in **Preferences**; every advanced setting is in the
[configuration reference](docs/configuration.md).
Managed `mlx_lm` requires a startup model in Preferences (`mlxModel` in JSON);
attached MLX servers need no Hearth-side model setting.

## Security

Full Hearth is signed, notarized, and unsandboxed for process supervision. Alerts
carry Hearth status; log excerpts require an explicit opt-in. Runner endpoints
default to `127.0.0.1`. See the
[privacy policy](PRIVACY.md) and [network guide](docs/reverse-proxy.md).

## Learn more

- [Documentation index](docs/README.md)
- [FAQ](docs/faq.md) and [troubleshooting](docs/troubleshooting.md)
- [How Hearth works](docs/how-it-works.md)
- [Product plan](docs/product-plan.md)
- [Running headless](docs/running-headless.md)

Contributions are welcome; start with the [development guide](docs/development.md).
Released under the [MIT License](LICENSE) with no third-party dependencies.
