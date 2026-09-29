<!-- SPDX-License-Identifier: MIT -->
# Hearth product plan

Updated September 29, 2026.

Make Ollama dependable on an unattended Mac: detect failures, recover safely,
and show what has actually been checked. Ollama is the primary setup and
validation path. Keep existing runner configurations compatible; use MLX as a
secondary path where a local workload needs it.

Validation uses automated tests and the maintainer's own workloads. No
recruitment, interviews, or external test panel is required. These checks can
establish usefulness for those workloads, not market demand.

## Current state

| Work | Status |
| --- | --- |
| Recovery decisions and inference evidence | Implemented; unit, HTTP, and real Ollama checks passed |
| Request activity through the metrics proxy | Implemented; pooled connections, streaming, cancellation, and framing tested |
| Setup validation and UI cleanup | Automated setup checks and native renders passed; live interaction and actual login-agent installation still needed |
| Process exit, API wedge, inference wedge, crash loop, orphan cleanup | Five isolated managed drills passed |
| Real client path | Ollama and MLX inference passed; Caddy authentication and buffered/streamed Ollama requests passed |
| Sustained local workload | 72-hour run not started |
| Release | Pending remaining validation and signed-artifact checks |

Details: [inference evidence](inference-recovery.md), [request activity](request-activity.md),
[setup validation](setup-validation.md), and the [dated validation report](../VALIDATION-REPORT.md).

## Next steps

1. **Finish setup validation.** Check keyboard navigation, menu actions, copied
   commands, quit/relaunch, and reload on an unlocked desktop. Test actual
   login-agent installation in a dedicated environment. Current tests inject the
   installer to protect the normal service.

2. **Run a bounded 72-hour Ollama workload.** Use separate config, data, and ports.
   Include idle periods, streaming, long requests, and model loading/unloading.
   Measure idle overhead and record false alerts, unintended restarts, recovery
   time, and manual interventions. Clients need explicit retries; restoring the
   runner does not resume an interrupted job. This run is planned, not scheduled.

3. **Release if the workload shows useful recovery.** Resolve false restarts,
   probe-created idle loads, and leaked processes. Run CI and real-runner checks,
   verify signed packages, and document the tested hardware, observation window,
   and remaining limits. Keep raw logs, prompts, credentials, and personal paths
   out of published evidence.

Compare controlled failures with the existing service manager where practical.
Synthetic drills do not establish long-term reliability or real Metal OOM
behavior. The current checks use one Mac and small models; other hardware and
macOS versions remain unverified.

## Scope

Prioritize recovery correctness and a usable Ollama setup. Defer new runners,
fleet management, model playgrounds, and paid packaging. If the workload shows
little benefit, stop expanding the feature set. If recovery helps but setup is
awkward, fix setup first.

Release download counts are not active-user counts. At the September 7 review,
the Homebrew tap's hourly sync downloaded the DMG before checking whether its
cask was current. Counts included that automation; independent usage is unknown.
