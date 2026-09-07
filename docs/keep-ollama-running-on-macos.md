<!-- SPDX-License-Identifier: MIT -->
# Keeping Ollama running on macOS

Common causes of an unavailable local Ollama server:

- **Memory pressure:** the model or context exceeds available unified memory.
- **Inference hang:** Metal or the model runner stalls while the server process
  remains alive.
- **Idle unload:** Ollama evicts a model, making the next request pay a cold load.
- **Sleep:** the Mac suspends the service.

Start with a smaller quantization or context, inspect
`~/.ollama/logs/server.log`, and set `OLLAMA_KEEP_ALIVE` when cold loads are the
problem. `launchd` or `brew services` can relaunch an exited process.

Hearth adds API and inference readiness checks, bounded restart recovery, sleep
prevention, alerts, and repeated model-memory diagnosis:

```sh
brew install --cask adamskijow/tap/hearth
open /Applications/Hearth.app
```

Use managed mode when Hearth owns a Homebrew `ollama serve`. Use attached mode
with Ollama.app or another service manager. See [Ollama setup](ollama.md),
[How Hearth works](how-it-works.md), and [Troubleshooting](troubleshooting.md).
