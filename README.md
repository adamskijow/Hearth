# Hearth

Hearth keeps Ollama running on an unattended Mac. It restarts crashed or
unresponsive servers, keeps the Mac awake, and sends failure alerts. Optional
inference checks catch hangs that leave the HTTP API responding.

Requires macOS 14 or later on Apple silicon. Independent of Ollama.

## Install

With Ollama already installed:

```sh
brew install --cask adamskijow/tap/hearth
open /Applications/Hearth.app
```

Open Preferences from the flame in the menu bar:

- **Hearth starts runner:** Hearth owns and restarts `ollama serve`. Stop any
  existing `brew services` job first.
- **Watch existing runner:** use this with Ollama.app or another service manager.
  Hearth checks health and alerts; the existing manager handles restarts.

See [Ollama setup](docs/ollama.md) for configuration and ownership checks.

## Inference checks

In Preferences, choose the model your apps use for inference checks. Scheduled
checks run only while that model is loaded. Automatic recovery from inference failures also
requires client requests through Hearth's metrics proxy. Direct requests are
invisible to Hearth; see [recovery limits](docs/limitations.md).

Process exits and API failures recover in managed mode without the proxy.
[Watch a recovery demo](assets/wedge-recovery.gif).

[Documentation](docs/README.md) · [Troubleshooting](docs/troubleshooting.md) ·
[Privacy](PRIVACY.md) · [Contributing](CONTRIBUTING.md) · [MIT license](LICENSE)
