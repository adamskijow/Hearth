<!-- SPDX-License-Identifier: MIT -->
# Keeping Ollama running on macOS

If you run Ollama on an always-on Mac (a Mac mini, a home-lab box, or a desktop
left on overnight) and it keeps stopping, hanging, or dropping offline, this is
the short version of why it happens, what you can try, and where Hearth fits.

## Is this you?

- Ollama **stops responding after a while** and you restart it by hand.
- The server is **up but requests hang forever**, with nothing useful in the logs.
- Ollama **dies overnight on a Mac mini** (or any always-on Mac) and nothing brings
  it back.
- It **falls back to CPU, or the GPU hangs**, and generations crawl for hours.
- The model **unloads after a few minutes idle**, so the next request pays a long
  cold start.
- You want `ollama serve` to be an **always-on service on Apple Silicon** that
  survives crashes, sleep, and reboots.

## Why it happens

Several distinct failures hide behind "Ollama stopped working":

- **Memory pressure.** A model too large for the Mac's unified memory, or other
  apps competing for it, gets the runner killed by macOS (jetsam). Common on 8 to
  16 GB Macs with a large model.
- **A GPU or model hang.** The Metal GPU wedges, sometimes after another local
  workload such as image generation, and the HTTP server keeps answering while
  generations never return. The process is still alive, so anything that watches
  the *process* sees nothing wrong.
- **Idle model unload.** By default Ollama unloads a model after about five minutes
  idle, so the next request reloads it slowly. Not a crash, but it reads like one.
- **Sleep.** A Mac with nobody logged in idle-sleeps, and the server stops serving
  until something wakes it.

## What you can try first

These help even without any extra tooling:

- **Keep the model loaded:** set `OLLAMA_KEEP_ALIVE` to a negative value like `-1`
  (via `launchctl setenv OLLAMA_KEEP_ALIVE -1`, or the Ollama app's environment) so
  it does not unload on idle. A value of `0` unloads immediately, which is the
  opposite of what you want here.
- **Fit the model:** use a smaller or more-quantized model, or lower the context
  length (`num_ctx`), so it fits in memory, and close memory-hungry apps.
- **Run it as a service:** a launchd plist, or `brew services` with `KeepAlive`,
  relaunches the runner when the *process exits*.
- **Read the logs:** `~/.ollama/logs/server.log` usually shows an out-of-memory or
  load error at the moment of the crash.

## The gap those leave

`launchd` and `brew services` restart a process that **exited**. They do nothing for
the failure that wastes the most time: the runner is **still running but no longer
answering** (the GPU or model hang above). They also do not keep the Mac awake while
it serves, and they cannot tell you *which* model keeps running you out of memory.

## Where Hearth fits

[Hearth](../README.md) is a small macOS supervisor built for exactly this gap. It
checks whether Ollama is actually **responding** (readiness), not just whether the
process is alive, so it catches the wedge as well as the crash; it keeps the Mac
awake while serving; it restarts on a backoff instead of thrashing; and when a model
repeatedly runs the Mac out of memory, it **names the model** so you can swap it. It
runs on top of launchd, not instead of it, and it leaves Ollama and your models
untouched.

```
brew install --cask adamskijow/tap/hearth
open /Applications/Hearth.app
```

The mechanism, with a real GPU-crash recovery, is in [How it works](how-it-works.md);
the common fixes are in [Troubleshooting](troubleshooting.md).
