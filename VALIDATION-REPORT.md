# Hearth validation report

This dated evidence log records real-runner failures, fixes, and remaining gaps.
M4 added scenarios 1 through 5; M5 added hard-crash orphan recovery.

The recent gates below use isolated configuration, data, ports, and owned process
identities. The older `./scripts/validate-real.sh` targets normal runner state and
uses broad process cleanup; use it only in a dedicated test environment.

## September 7, 2026: request activity and UI

The [request-activity stage](docs/request-activity.md) replaces idle-connection
suppression with bounded HTTP framing observation. Adversarial review caught
unsolicited response bytes briefly appearing idle, stale callbacks erasing new
requests, asynchronous listener shutdown, and treating a termination signal as
proof of group death. A further overlap case involved an old server retaining its
port while the replacement exited. These now have conservative generation guards;
the final review found no remaining blocker.

The local gate passed **528 tests in 83 suites**, debug/release builds, and lint.
The isolated HTTP gate passed:

- API, CLI, and metrics retaining an inference failure until validated completion.
- Reusing the same idle keep-alive socket while scheduled inference succeeds.
- A silent chunked response remaining active beyond the 30-second busy timeout,
  with no probe or unintended restart; final framing permits checks again.
- Byte-exact pipelining, trailers, binary body data, and client write-half-close.
- Unsupported chunk extensions forwarding unchanged while activity stays unknown.
- Reset cancellation preserving uncertainty and explicit partial visibility.

The byte-exact gate initially failed: connection-state failure arrived before the
second buffered response and clean EOF. Immediate cross-cancellation truncated
the reply. The relay now drains through I/O completions; the same reproduction
and full gate pass. Raw traces remain local.

The isolated real Ollama check passed startup without loading an idle model,
proxied inference, controlled process exit, automatic recovery, renewed verified
inference after group shutdown, and exact owned-process cleanup. No installed
service was stopped or reconfigured.

Preferences and Welcome were rendered natively in light and dark appearances.
The pass groups setup into focused pages, exposes the selected client endpoint,
masks credentials, clarifies ownership, and removes unsupported health claims.
Live keyboard/menu interaction remains unverified because the Mac was locked.
The full clean-setup matrix, Caddy runtime check, and bounded 72-hour workload
remain pending. This is source validation, not a binary release.

## September 7, 2026: adversarial review and structured evidence

An independent adversarial agent reproduced stale effects killing a replacement
child, false inference recovery after respawn, deep HTTP 503 bypassing the traffic
policy, and attached-session scheduling leakage. The subsequent patch adds
regressions for those cases, validates completed responses, and requires loaded-
model evidence for scheduled checks. A second review caught stale verification
after observed process death and notification delivery delaying teardown. Both
were corrected; the final focused review found no remaining blocker.

The local gate passed **508 tests in 81 suites**, debug and release builds, and
lint. The isolated HTTP/CLI/metrics/heartbeat gate passed with a pooled connection
held beyond the busy timeout. Inference failures stayed visible, no recovery or
new probe occurred while the connection was held, and a validated completion
cleared the incident after closure.

A separate isolated real Ollama run passed startup with the model unloaded,
explicit proxied generation, and `inferenceVerified: true` from the automatic
completion validator. Killing only its recorded runner process triggered
recovery; another real generation completed afterward. Shutdown removed the
owned process groups and isolated state. No normal service was reconfigured.

This is source validation, not a binary release or the planned 72-hour workload.
LM Studio completion shapes are fixture-tested; they were not revalidated against
its live server in this pass. MLX and Osaurus scheduled checks now defer because
their catalog responses do not prove residency. Request-level traffic visibility
and unobserved external replacements in attached mode remain limitations.

## September 7, 2026: inference status and proxy deferral

The [first implementation](docs/inference-recovery.md) adds regression coverage
for withheld inference recovery, proxy connections across the busy timeout, a
client arriving during a failed probe, and an old-session probe result.

`python3 scripts/validate-inference.py` passed against the debug executable with
an isolated fake HTTP/1.1 runner and real clients: API/CLI/metrics retained a
confirmed inference failure, an idle pooled connection remained open beyond the
30-second busy timeout without recovery, and successful inference cleared the
incident after closure. Heartbeats paused during the unresolved incident and
resumed after successful inference. Configuration and data were temporary.

A separate isolated managed Ollama run used the installed `qwen2.5:0.5b` model
and temporary runner, control, and proxy ports. Startup left the model unloaded;
explicit proxied generation succeeded. A SIGKILL of that instance's recorded
runner triggered automatic recovery, followed by successful real inference.
Stopping supervision removed its recorded state and both owned process groups.
No installed service was stopped or reconfigured. This was a bounded lifecycle
check, not the planned 72-hour workload or a real Metal/GPU-wedge reproduction.

## Environment

- macOS 26.5.1 (build 25F80), Darwin kernel 25.5.0.
- Apple M5 Max, 128 GiB unified memory (107 GiB reported available to the GPU).
- Ollama 0.30.11 (Homebrew, `/opt/homebrew/bin/ollama`).
- Model: `qwen2.5:0.5b` (Q4_K_M, 397 MB on disk).
- Unsigned debug build (`swift build`); no signing or notarization was attempted.
- Gatekeeper was outside this debug-build test. Release validation covers
  Developer ID signing and notarization separately.

## Ground truth: the real process tree

`ollama serve` forks a `llama-server` child when a model loads. Both share a
process group, which caused the teardown defect.

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

`state=T` is the kernel's "stopped" state: the PID is alive, while the HTTP probe
times out and reports Down. This verifies readiness detection on a real process.

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

## Live GPU-crash test

Scenarios 1 through 6 use signals. On 2026-07-02, image generation caused a GPU
crash while Ollama served a 14 GB model. Hearth observed the real inference wedge
and full failure ladder.

Setup: Ollama 0.30.11 serving `qwen2.5:14b-instruct` (14 GB resident, 32K context).
Two instruments, both independent of the machine's live managed daemon (which was a
pre-0.9.0 binary, not the subject of the detection claims):

- a ground-truth probe loop every 2s: a shallow `GET /api/version` and a deep
  one-token `POST /api/generate`, both timed;
- a fresh 0.9.0 build in attached mode with a deep probe (`probeModel
  qwen2.5:14b-instruct`), reporting via its control endpoint. Attached mode never
  spawns or kills, so it only observed.

### Episode 1: an inference wedge a shallow probe misses

As the image model loaded and contended for the GPU, deep-probe latency climbed and
then hung, while the shallow HTTP endpoint stayed instant throughout:

```
baseline      shallow ~0.5ms   deep 0.25-0.6s      healthy
12:47:58      shallow ~0.5ms   deep 1.23s          (GPU starting to starve)
12:48:07      shallow ~0.5ms   deep 10.0s TIMEOUT  <- inference wedged
12:48:19..43  shallow ~0.5ms   deep 10.0s TIMEOUT  (sustained ~40s)
12:48:55      shallow ~0.5ms   deep 0.34s          <- recovered on its own
```

The 0.9.0 watcher reported `lastDown=wedged`, phase down then restarting.
`ollama serve` (74418) and its `llama-server` child (98378) never changed pid: the
wedge cleared by itself once the GPU freed, so no restart was needed. This is
scenario 3's liveness-vs-readiness result on a real GPU wedge instead of a SIGSTOP.
`/api/version` answered in half a millisecond the entire time a liveness check
would have called the runner healthy, while a real one-token generation hung for 40
seconds. Only the deep probe caught it.

### Episode 2: heavier contention, then kill, crash loop, recovery

A second, heavier generation pushed unified memory to exhaustion and took the whole
server down, not just inference:

```
12:50:32   deep FAIL, shallow ok        (inference wedge again)
12:50:42   shallow FAIL + deep FAIL     (whole endpoint wedged, process still alive)
12:50:45   ollama serve killed          (memory pressure), watcher=down
12:51:03   watcher=failing              (crash-loop state entered)
12:51:10   a respawn (new pids) that died again under the continued load
12:51:35   shallow ok + deep ok         (recovered), fresh serve 16645 / llama 16739
12:51:42   watcher=healthy
```

The original `ollama serve` (74418) was killed under memory pressure (a macOS jetsam
SIGKILL, not an Ollama-internal allocation error), respawned, died again under the
sustained load, and finally came back healthy as a fresh process once the image
generation released memory. The live managed daemon (still running) is what
respawned it through the crash loop; the 0.9.0 watcher independently tracked the
same episode through down, failing, and healthy.

### Caveats

- The streaming monitor tracked pids with `pgrep -f "ollama serve"`, whose pattern
  also matched the monitor's own command line, so its per-sample pid columns were
  unreliable (they bounced to the monitor's own pid). The trustworthy signals are
  the shallow/deep latencies and a full-path `pgrep -fl "/opt/homebrew/bin/ollama
  serve"` check, which confirmed the real restart 74418 -> 16645. An earlier read
  of the streaming pids as a restart was wrong and was corrected.
- One machine, one run; not a scripted, repeatable gate like scenarios 1 through 6.
- The run leaves the out-of-memory classification gap below. A jetsam SIGKILL
  carries no `ggml`/`metal` stderr signature (those come from Ollama's own Metal
  allocation-failure path, a different mode than the OS killing the process), and
  the runner stderr at the crash was not captured. What the run does show is the
  behavior Hearth handles: deep-probe detection of a real GPU wedge, and a real
  memory-pressure process death, crash loop, and recovery.

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

Revalidated on 2026-08-15 against a fully isolated current install:

- MLX-LM 0.31.3 and MLX 0.32.0 in a Python 3.12 virtual environment.
- `mlx-community/Qwen2.5-0.5B-Instruct-4bit` in a new, empty `HF_HOME` (282 MB).
- macOS 26.6.1 on Apple silicon.
- A separate `HEARTH_CONFIG`, `HEARTH_DATA_DIR`, and port 18080, leaving the
  installed Hearth instance untouched.

The live runner log proves the exact launch contract:

```
=== spawn mlx_lm.server --model mlx-community/Qwen2.5-0.5B-Instruct-4bit --host 127.0.0.1 --port 18080 ===
```

The server downloaded the model into the empty cache, `/v1/models` returned its
ID, and an OpenAI-compatible chat request completed on Metal with fingerprint
`0.31.3-0.32.0-macOS-26.6.1-arm64-arm-64bit-applegpu_g17s`. After an external
SIGKILL, Hearth recorded the failure, scheduled a bounded restart, spawned a new
PID, restored the same model, and completed a second real inference request.
Clean Hearth shutdown left no MLX process or listener behind.

A second configuration omitted `mlxModel`. `hearth doctor` exited 1, headless
Hearth exited 2 before supervision, and the test port stayed free. Incomplete
managed MLX configuration therefore fails closed.

MLX-LM printed its upstream production warning about basic security checks. Hearth
mirrors it for non-loopback binds. `/v1/models` can answer during a first-time
model download, so shallow health proves API reachability; `probeModel` verifies
inference.

### LM Studio (attached validated; managed unsupported)

Attached mode, against an externally started `lms server start`:

```
attached /status: {"phase":"healthy","restartCount":0,"models":[],...}
Hearth spawned no server of its own (attached mode)
```

Attached Hearth reaches Healthy against the external server (`/v1/models` and
`/api/v0/models` both 200) while leaving ownership with LM Studio.

Managed mode is unsupported and flagged by `hearth doctor` and the menu. `lms
server start` tells LM Studio's background process to serve, then exits. Hearth
would restart that short-lived client while the server remains up:

```
Hearth managed /status: phase down, restarts 3
the server itself:      GET /v1/models -> 200   (up the whole time)
```

There is no foreground flag for `lms server start`, so LM Studio is attached only.

## Remaining gap

Honest gaps, with the steps to close each.

- Real out of memory classification. Not inducible on 128 GiB hardware. The live
  GPU-crash test above produced a real memory-pressure kill, but as a jetsam
  SIGKILL with no `ggml`/`metal` stderr, so it does not exercise the OOM signature
  path (a different failure mode).
  - To verify: on a smaller-memory Mac, run a model far larger than RAM, or set
    a very large context, capture the runner stderr at the crash, and confirm
    `classifyExit` returns `.outOfMemory`. `scripts/capture-oom.sh <model>`
    automates the capture and checks it against the shipped signatures.

## How to reproduce

```
brew install ollama
ollama serve >/dev/null 2>&1 & ollama pull qwen2.5:0.5b ; kill %1
./scripts/validate-real.sh
```

Stop the Homebrew service first; the script manages its own `ollama serve`.
