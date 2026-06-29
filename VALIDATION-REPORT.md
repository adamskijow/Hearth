# Hearth validation report

This records validating Hearth against a real Ollama for the first time (it had
only ever run against a fake Python runner), the defects that surfaced, the fixes,
and what remains unverified. M4 added scenarios 1 through 5 (lifecycle and process
group teardown); M5 added scenario 6 (hard-crash orphan recovery). Evidence is raw
command output, not prose claims.

Reproduce with `./scripts/validate-real.sh` (requires a real Ollama and a small
pulled model). The script exits non-zero on any failed scenario.

## Environment

- macOS 26.5.1 (build 25F80), Darwin kernel 25.5.0.
- Apple M5 Max, 128 GiB unified memory (107 GiB reported available to the GPU).
- Ollama 0.30.11 (Homebrew, `/opt/homebrew/bin/ollama`).
- Model: `qwen2.5:0.5b` (Q4_K_M, 397 MB on disk).
- Unsigned debug build (`swift build`); no signing or notarization was attempted.
- Gatekeeper note: the dev binary is run directly from `.build`, so it is not
  quarantined and Gatekeeper does not gate it; a distributed `.app` would need
  Developer ID signing and notarization (out of scope for this phase).

## Ground truth: the real process tree

`ollama serve` forks a separate `llama-server` child once a model loads. Both
share a process group. This is the crux of the teardown defect.

```
  PID  PPID  PGID COMM
78869     1 78867 /opt/homebrew/bin/ollama serve
78885 78869 78867 /opt/homebrew/Cellar/ollama/0.30.11/libexec/lib/ollama/llama-server --model .../sha256-... --port 57282 --host 127.0.0.1 ...
```

So killing only the `ollama serve` PID leaves `llama-server` (which holds GPU and
unified memory) orphaned and re-parented to launchd.

## Scenario results

| # | Scenario | Before fix | After fix |
|---|----------|------------|-----------|
| 1 | Cold start to Healthy; real `/api/ps` parsed | PASS | PASS |
| 2 | External SIGKILL detected, restarted, no orphan | (orphan) | PASS |
| 3 | SIGSTOP wedge caught by readiness while PID alive; no orphan | partial: caught, but orphan | PASS |
| 4 | Clean shutdown reaps the whole process group | FAIL (orphan) | PASS |
| 5 | Attached mode: readiness only, no spawn or kill | PASS | PASS |
| 6 | Hard-crash orphan recovery: a SIGKILLed Hearth's leaked group is swept on next launch | (leak) | PASS |

The final run is 17 checks passed, 0 failed; the script exits 0. A run with any
failure exits 1 (the first run, before the fix, exited 1 with 3 failures).
Scenario 6 was added in M5; scenarios 1 through 5 are the original M4 gate.

### Scenario 1 (real /api/ps parsing)

```
PASS: reached Healthy (serve pid 79579)
/status: {"consecutiveFailures":0,"memoryUsedPercent":26,"models":["qwen2.5:0.5b"],"phase":"healthy","restartCount":0,"runnerResidentBytes":61734912,"thermal":"nominal","uptimeSeconds":4}
PASS: resident model visible via /status
```

The resident model name is parsed from the live `/api/ps`, not a fixture.

### Scenario 3 (the liveness vs readiness differentiator)

```
SIGSTOP ollama serve pid 79652; llama-server child: [79695]
at detection: phase=down pid=79652 state=T
PASS: readiness flagged not-Healthy while PID 79652 was still alive (state T); a liveness check alone would miss this
PASS: recovered to Healthy with a new serve pid 79777
```

`state=T` is the kernel's "stopped" state: the PID is alive, so a liveness check
passes, but readiness (the HTTP probe) times out and correctly reports Down. This
is the core thing Hearth claims to do, now shown on a real process.

### The defect, before the fix

The orphan check after a wedge restart and after a clean shutdown both failed:

```
# after wedge restart
llama-server pids: [79055]; current serve: 79125; strays (not child of current serve): [79055]
FAIL: orphaned llama-server after wedge restart: 79055

# after clean shutdown
after stop:  serve=[] llama-server=[79055]
FAIL: orphans after clean shutdown: serve=[] llama-server=[79055]
```

`llama-server` 79055 outlived the serve it belonged to and persisted through a
clean stop, leaking memory across restarts.

### After the fix

```
# Scenario 2: external SIGKILL
killing ollama serve pid 79579 (SIGKILL); its llama-server child: [79602]
PASS: restarted to Healthy with a new serve pid 79652
llama-server pids: []; current serve: 79652; strays: []
PASS: no orphaned llama-server after external SIGKILL + restart

# Scenario 4: clean shutdown
before stop: serve=[79777] llama-server=[79816]
after stop:  serve=[] llama-server=[]
PASS: clean shutdown left no ollama serve and no llama-server
```

## The fix

Two changes, both confirmed by the orphan checks above:

1. `FoundationProcessController` now spawns the runner with `posix_spawn` and
   `POSIX_SPAWN_SETPGROUP`, making the child the leader of a new process group,
   and tears the whole group down with `killpg` (SIGTERM, then SIGKILL after a
   grace). `killpg` reaches the `llama-server` grandchild because it inherits the
   group.
2. The engine sweeps the previous runner's group before each respawn
   (`terminate` on the old handle, then `spawn`). An external kill or a crash
   bypasses Hearth's own teardown, so without this a single externally killed
   serve would still orphan its child; the pre-spawn sweep reaps it before a
   replacement starts, so a restart loop cannot stack up leaked runners.

The pre-spawn sweep decision is unit tested through the process-control seam
(`respawnSweepsThePreviousRunnerBeforeSpawning`); the OS level group teardown is
verified live by the orphan checks above.

### Follow-up finding: inherited signal state

A later run of the fake-runner smoke test surfaced a related defect the real
Ollama had hidden. Hearth sets SIGTERM/SIGINT/SIGHUP to SIG_IGN for its own
signal handling, and libdispatch leaves them blocked; both the ignore and the
blocked mask survive `posix_spawn` and `exec`. So a runner that does not reset
its own signal state started with Hearth's SIGTERM ignored and blocked, and would
not die from the graceful teardown, only from the SIGKILL backup. Real Ollama (a
Go binary that resets its signal mask at startup) hid this; the fake Python runner
exposed it by surviving SIGTERM entirely. Fixed by spawning the runner with
`POSIX_SPAWN_SETSIGDEF` (default dispositions) and `POSIX_SPAWN_SETSIGMASK` with an
empty mask (no blocked signals). The fake runner now dies on a clean SIGTERM, and
the real Ollama gate still passes.

## M5: hard-crash orphan recovery (Scenario 6)

The process-group teardown above covers every exit Hearth gets to observe. The
one exit it cannot observe is its own hard death. If Hearth is SIGKILLed it never
runs teardown, so the runner group it spawned is left behind, reparented to
launchd, holding GPU and unified memory.

Hearth now records the runner's PID, process group, and start time to
`runner-state.json` on every spawn, and sweeps any still-alive recorded group on
the next launch before starting fresh. The start time is the safety guard: a PID
reused by an unrelated process has a different start time, so a recycled PID is
never killed (`RunnerSweepTests`). Scenario 6 proves it end to end against real
Ollama:

```
Scenario 6: a hard SIGKILL of Hearth leaks the runner group; the next launch sweeps it
  PASS: reached Healthy before the simulated crash (serve 85114)
  before crash: serve=85114 llama-server=[85131]; state recorded: yes
  PASS: the hard kill orphaned the runner (serve 85114 survived, reparented to launchd)
  PASS: next launch swept the orphaned serve 85114
  PASS: the orphaned llama-server grandchild was swept too
  PASS: recovery was logged on the next launch
```

The orphaned `llama-server` grandchild (85131) dies with the group because the
sweep uses `killpg` on the recorded process group, not just the serve PID. The
residual gap is only the window between the crash and the next launch.

## Real API fixtures

Captured into `tests/Fixtures/real/` and reconciled with the parser. A
real-fixture unit test (`parseRealPSCaptureFromOllama`) asserts the parse,
including the microsecond-and-offset `expires_at`.

`/api/version`:

```json
{"version":"0.30.11"}
```

`/api/ps` (resident model) carries more fields than the hand-written fixtures
(`digest`, `details`, `size_vram`, `context_length`) and a timezone-offset
timestamp:

```json
{"models":[{"name":"qwen2.5:0.5b","model":"qwen2.5:0.5b","size":928755219,"digest":"a8b0c5...","details":{"format":"gguf","family":"qwen2","parameter_size":"494.03M","quantization_level":"Q4_K_M"},"expires_at":"2026-06-28T07:22:51.358551-04:00","size_vram":928755219,"context_length":32768}]}
```

The parser reads `name`, `model`, `size`, and `expires_at` and ignores the rest;
the lenient ISO 8601 decoder parses the microsecond-and-offset timestamp to a
real date (the test asserts the year is 2026, not the epoch fallback).

## Exit classification (out of memory vs crash)

Checked the default OOM stderr signatures against a real Ollama 0.30.11's normal
output: none of them appear, so they will not false-positive a healthy runner.
Normal logs do contain `ggml_metal_init` and lots of `memory` lines, but not the
exact signatures (`ggml_metal_graph_compute`, `metal buffer`, etc.).

Correction made: removed the bare token `oom` from the signatures. It is a
substring of common words (room, zoom, boom) and is redundant with
`out of memory` / `outofmemory`.

UNVERIFIED: a real out of memory kill could not be induced. This machine has
128 GiB of unified memory, so an oversized model or a very large context does not
reliably OOM. The Metal specific signatures in particular remain heuristics; they
are confirmed absent from healthy output but never confirmed to fire on a real
Metal OOM. See the closing list for how to capture a real signature later.

## Log rotation

`runner.log` grew without bound (thousands of lines in a few runs). Added size
based rotation. Verified live with a 3 KB cap and three kept files: the directory
settles at the active log plus exactly three rotated files, oldest deleted.

```
runner.log      185 bytes   (active)
runner.log.1   3127 bytes
runner.log.2   3116 bytes
runner.log.3   3941 bytes
```

The rotation decision and rename plan are unit tested (`LogRotationTests`).

## LM Studio and mlx_lm (validated against live servers)

Both were later run against real servers, not just captured payloads.

### mlx_lm (managed, validated)

`pip install mlx-lm`, then Hearth in managed mode (`mlxBinaryPath` pointed at the
installed `mlx_lm.server`):

```
final /status: {"models":["mlx-community/Qwen2.5-0.5B-Instruct-4bit"],"phase":"healthy","restartCount":0,"runnerResidentBytes":100319232,...}
SIGKILL the mlx server -> phase healthy, restarts 1   (Hearth detected and restarted it)
clean stop -> no mlx_lm.server strays
```

Managed mlx_lm works: cold start to Healthy, resident model parsed from
`/v1/models`, restart on external kill, clean teardown. One caveat: with an empty
HuggingFace cache (no MLX model ever downloaded), `mlx_lm.server`'s `/v1/models`
returns 200 then throws `CacheNotFound`, so readiness never passes. Any real mlx
user has a model, so the cache exists; the empty-cache state is a non-issue in
practice but is documented.

### LM Studio (attached validated; managed does not work)

Attached mode, against an externally started `lms server start`:

```
attached /status: {"phase":"healthy","restartCount":0,"models":[],...}
Hearth spawned no server of its own (attached mode)
```

Attached works: Hearth reaches Healthy watching the external server (`/v1/models`
and `/api/v0/models` both 200) and does not spawn or kill it.

Managed mode does NOT work, and this is now flagged by `hearth doctor` and the
menu. `lms server start` is a client command that tells LM Studio's background
process to serve and then exits immediately, so Hearth's spawned child dies at
once and the liveness check restarts it in a loop while the server is actually up:

```
Hearth managed /status: phase down, restarts 3
the server itself:      GET /v1/models -> 200   (up the whole time)
```

There is no foreground flag for `lms server start`, so LM Studio is attached only.

## Still UNVERIFIED

Honest gaps, with the steps to close each.

- Real out of memory classification. Not inducible on 128 GiB hardware.
  - To verify: on a smaller-memory Mac, run a model far larger than RAM, or set
    a very large context, capture the runner stderr at the crash, and confirm
    `classifyExit` returns `.outOfMemory`. Add the captured lines as a fixture.

## How to reproduce

```
brew install ollama
ollama serve >/dev/null 2>&1 & ollama pull qwen2.5:0.5b ; kill %1
./scripts/validate-real.sh
```

The script manages its own `ollama serve`; do not leave the brew service running.
