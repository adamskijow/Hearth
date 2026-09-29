<!-- SPDX-License-Identifier: MIT -->
# Keeping Ollama running on macOS

Common causes of an unavailable or slow local Ollama server:

- **Memory pressure:** the model or context exceeds available unified memory.
- **Inference hang:** Metal or the model runner stalls while the server process
  remains alive.
- **Idle unload:** a model leaves memory, so the next request must load it again.
  This is a cold start, not a failed server.
- **Sleep:** the Mac suspends the service.

For memory pressure, try a smaller quantization or context. For cold loads,
review Ollama's `OLLAMA_KEEP_ALIVE` setting. Use `hearth logs` for a Hearth-managed
server or `~/.ollama/logs/server.log` for Ollama.app; see [Ollama troubleshooting](https://github.com/ollama/ollama/blob/main/docs/troubleshooting.mdx).
`launchd` or `brew services` can relaunch an exited process.

Hearth adds API and inference readiness checks, bounded restart recovery, sleep
prevention, alerts, and warnings about repeated memory-related failures:

```sh
brew install --cask adamskijow/tap/hearth
open /Applications/Hearth.app
```

Use managed mode when Hearth owns a Homebrew `ollama serve`. Use attached mode
with Ollama.app or another service manager. See [Ollama setup](ollama.md),
[How Hearth works](how-it-works.md), and [Troubleshooting](troubleshooting.md).
