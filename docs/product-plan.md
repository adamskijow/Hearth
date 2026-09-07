<!-- SPDX-License-Identifier: MIT -->
# Hearth product plan

Updated September 7, 2026. This plan focuses on full Hearth.

## Objective

Make unattended Ollama and MLX service on Mac dependable, with accurate health
reports and a setup path that verifies the protection actually enabled.

Progress depends on reproducible tests and the maintainer's own workloads.
This plan requires no recruitment, interviews, user panels, or external testers.
It can establish reliability and usefulness for those workloads; it does not
claim market demand or willingness to pay.

GitHub release-asset download counts are not evidence of active users. As of this
review, the [Homebrew cask sync workflow](https://github.com/adamskijow/homebrew-tap/blob/main/.github/workflows/sync-hearth.yml)
downloads the latest DMG on each hourly run before checking whether the cask is
already current. The counts therefore include our own automation; the share of
independent downloads is unknown.

## Milestones

| Order | Work | Completion evidence |
| --- | --- | --- |
| 0 | Finish repository cleanup | Clean, synchronized repository; documentation matches implemented behavior |
| 1 | Reproduce traffic/recovery defects and define health states | Isolated scenario results and an additive status contract |
| 2 | Fix recovery decisions and misleading health reports | Regression suite plus real-client behavior consistent across status surfaces |
| 3 | Verify setup from a clean configuration | Recorded setup matrix with a real inference request through the configured client endpoint |
| 4 | Run controlled failures and representative local workloads | Repeatable lifecycle checks and a bounded 72-hour local run |
| 5 | Release the focused improvement | CI, package, diagnostics, documentation, and release evidence all agree |

Each milestone produces one reviewable change or a small sequence of changes.
Advance when its evidence is complete; elapsed time alone is not a completion
condition. The 72-hour run is future validation work, not a scheduled task.

The [inference implementation](inference-recovery.md) now separates API,
completed inference evidence, current check activity, and recovery eligibility.
It fixes the reproduced false recovery and stale-effect defects, validates
completed responses, and explicitly defers adapters without residency evidence.
[Request-level traffic observation](request-activity.md) now distinguishes idle
pooling from active work and preserves cancellation uncertainty until owned
group shutdown is confirmed. The UI and generated client endpoint have also
been updated. Clean setup, the bounded workload, and release remain pending.

## 1. Reproduce before changing recovery policy

Use an isolated fake runner and real HTTP clients, with dedicated config, data
directory, and ports. Target `MetricsProxy.swift`, `SupervisorEngine.swift`,
`SupervisorAssembly.swift`, and the existing engine tests.

| Scenario | Required result |
| --- | --- |
| Idle pooled HTTP connection | Distinguish an open connection from active work; avoid silently suppressing checks |
| Healthy long streaming or silent-prefill request | Preserve legitimate work; report what has actually been verified |
| Stalled request with a responsive API | Surface unverified or stalled inference, without treating a connection as proof of progress |
| Direct and proxied clients together | Report incomplete visibility; one observed connection cannot prove every client uses the proxy |
| Client begins work while a probe is pending | Re-evaluate evidence before a destructive decision |
| Probe model missing, renamed, or unloaded | Show inference not checked and a useful next action |
| Cold model startup | Avoid probe-created load and false restart loops |
| Repeated inference failures with recovery withheld | Show the failure and the reason automatic recovery is unavailable |
| Managed process death or API hang | Preserve bounded recovery and process-group cleanup |

Exercise the interaction between probe cadence, open connections, and
`busyTimeoutSeconds`. The engine converts a sustained busy streak to failure,
while intervening non-busy observations reset that streak. Validate both skipped
checks and possible false escalation rather than assuming one outcome.

Acceptance: a short before/after evidence table and meaningful regression cases
for each confirmed defect. A fixed elapsed timeout or missing streamed token is
not sufficient evidence of a wedge during legitimate prefill.

## 2. Make health and recovery coverage explicit

Expose separate API, inference, and recovery fields in the shared state:

- API: responding, unavailable, or not yet checked.
- Inference: verified, failed, checking, deferred, or not configured; include the
  checked model, last success, freshness, and deferred reason.
- Recovery: managed or attached, covered failure types, and any missing evidence.

Prioritize the current case where repeated inference failures leave the
supervisor phase healthy. Preserve conservative process control while making
the inference failure visible. A shallow API success must not clear a known
inference incident.

Use additive fields to preserve the documented 1.x API/config contract. Update
the menu, CLI, browser status page, metrics, and documentation consistently.
Keep compatibility with existing status-only clients.

For traffic visibility, compare runner-native signals and a bounded
protocol-aware approach before expanding the TCP relay. Test streaming,
connection reuse, cancellation, framing, and client bypass for any selected
approach. Unknown activity must reduce claimed recovery coverage.

Acceptance: consistent results across status surfaces; no unintended restart in
the scenario matrix; recovery recorded only after the relevant check succeeds.

## 3. Complete one setup path

Target `Welcome.swift`, `Preferences.swift`, `SetupCLI.swift`, and
`ProxySetupCLI.swift`.

The path should detect the runner and owner, explain managed versus attached
coverage, select the real workload model, configure necessary traffic visibility,
show the exact client endpoint, verify real inference, and offer a test alert.

Prefer observed workload or resident models over the smallest installed model.
Make the proxy's role in recovery visible alongside inference checks. Generated
Caddy configuration now selects the observed client endpoint when enabled;
validate it through an actual Caddy instance in the clean-setup matrix.

Use temporary directories and isolated instances for this setup matrix:

- Homebrew Ollama with no competing manager.
- Existing Ollama.app or service manager, using attached mode.
- MLX with and without a required startup model.
- Missing runner, wrong port, occupied port, and unavailable selected model.
- Valid and malformed existing configuration.
- Direct clients, clients using the metrics proxy, and an authenticated reverse
  proxy in front of the selected path.
- Quit/relaunch, config reload, and cleanup without disturbing the normal install.

Acceptance: every successful path ends with a verified request and an accurate
coverage summary. Failed paths identify the exact correction. Inspect release-
sized UI, keyboard operation, and copied commands. Record steps and time for
maintainer-run clean setups; do not present them as independent usability tests.

## 4. Demonstrate value on local workloads

Use the available Mac and installed small Ollama/MLX models. Keep validation
isolated from the normal service and store raw evidence outside Git.

First run repeatable process-exit, API-wedge, inference-only-wedge, crash-loop,
and orphan-cleanup drills. Verify inference after recovery, not just a new PID.
Include bounded client retries and show that restoring service does not itself
resume an interrupted application job.

Then run a bounded 72-hour local workload with a mix of idle periods, streaming,
long requests, and model loading/unloading. Include a scheduled quiet period
with no requests to measure the monitoring overhead. Use existing local logs,
events, and metrics rather than introducing an analytics service.

Record:

- False alerts and unintended restarts.
- Detection and recovery time for each controlled incident.
- Successful post-recovery inference and any failed client requests.
- Idle memory/CPU use and unnecessary model loads.
- Setup friction and manual recovery steps required.
- Whether the maintainer's real workflow is easier to operate with Hearth.

Compare selected controlled scenarios with the current service-manager setup
where safe and practical. Label synthetic drills separately from natural
failures; do not claim saved hours from hypothetical outages.

Acceptance: every planned drill has recorded outcomes, zero observed false
automatic restarts, no probe-created idle model loads, and no leaked managed
processes after cleanup. Investigate failures rather than repeatedly rerunning
until a clean result appears. Report the observation window and hardware limits.

Use small models and controlled failures on available hardware. Memory-pressure
simulation does not establish real Metal OOM behavior. Older macOS or other
hardware checks remain explicitly unverified if those environments are not
available; they do not create an external-testing dependency.

## 5. Release and choose subsequent work

Run the shared CI, real-runner checks, and affected UI/packaging checks. Validate
signed release artifacts and keep the public evidence free of credentials,
personal paths, prompts, model responses, and raw logs.

Release when the supported recovery and setup cases pass, known limits are
accurate, and local workloads show a useful reduction in manual intervention.
Do not wait for user recruitment or a download-count target.

If the local workload reveals little benefit, keep Hearth a focused utility and
stop adding features. If recovery is useful but setup is cumbersome, prioritize
setup. Defer new runner integrations, fleet management, model labs, paid
packaging, and separate monitoring apps until the core milestones are done.

## Next implementation session

Complete the isolated clean-setup matrix in milestone 3, using the new focused
Preferences and consistent client endpoint. Finish live keyboard/menu checks
when an unlocked desktop is available, and verify real inference through Caddy.
Then run the controlled recovery drills before beginning the bounded 72-hour
workload. Preserve partial traffic visibility and the additive evidence contract.
No recruitment or outreach step precedes this work.
