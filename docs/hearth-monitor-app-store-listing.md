<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor App Store listing draft

This is the source of truth for the 0.2.0 listing. Recheck App Store Connect
field limits and localized text before submission.

## Product metadata

- Name: **Hearth Monitor**
- Subtitle: **Health checks for local AI**
- Primary category: **Utilities**
- Age rating: **4+**
- Privacy: **Data Not Collected**
- Support URL: `https://github.com/adamskijow/Hearth/issues`
- Privacy URL: `https://github.com/adamskijow/Hearth/blob/main/PRIVACY.md`

## Promotional text

Know when Apple Intelligence and the local AI runners on your Mac are actually
working, with private functional checks, confirmed incidents, and clear recovery
boundaries.

## Keywords

`Apple Intelligence,AI,LLM,Ollama,local,monitor,health,GPU,MLX,LM Studio`

## Description

Hearth Monitor is a private menu-bar health monitor for local AI on your Mac.
It requires no account, contains no analytics or advertising, and sends no data
to the developer.

APPLE INTELLIGENCE HEALTH

On a compatible Mac running macOS 26 or later, Hearth reads Apple's public
Foundation Models availability state. With your permission, it periodically asks
the on-device model for one tiny fixed response. The response is discarded
immediately; only timing, status, and confirmed incident metadata stay local.

Hearth distinguishes an unavailable or downloading model, unusual slowness, one
unconfirmed timeout, and a persistent functional failure. It requires two failed
checks before recording an incident or notifying you. It also refuses to stack a
new request behind one that timed out.

LOCAL AI RUNNERS

Attach to Ollama, LM Studio, mlx_lm, or Osaurus on this Mac, your private network,
or an HTTPS address you control. Hearth can check the API, show resident models,
and optionally request one token to catch an inference engine that is wedged even
while HTTP still responds. Protected runners can use a bearer credential stored
only in Keychain. Each runner can be paused without deleting its setup.

Inference checks default to a five-minute cadence, pause during sleep, Low Power
Mode, and serious thermal pressure, and run sequentially when you choose Check
All. For Ollama, a model loaded only for an automatic check is unloaded after the
check so monitoring does not pin unnecessary GPU memory.

LOCAL HISTORY AND ALERTS

Confirmed Apple Intelligence and runner incidents share one bounded local
history. Notifications, snooze, and Open at Login are optional. Scheduled Apple
and local-runner functional checks pause during sleep, Low Power Mode, and
serious thermal pressure.

HONEST RECOVERY

The App Store edition is a monitor. It can recreate its own Apple model session,
but macOS owns the underlying service. It never claims to restart Apple
Intelligence. It also never starts, stops, installs, or changes a local AI runner.

Users who separately install full Hearth can connect a status-only credential to
see whether managed runner restart and GPU-wedge recovery are active. This pairing
is optional and is not required for either monitoring mode.

Hearth Monitor is an independent project and is not affiliated with or endorsed
by Apple, Ollama, or the other supported runner vendors.

## What's new in 0.2.0

- Added zero-setup Apple Intelligence availability and optional functional health
  checks through Apple's on-device Foundation Models framework.
- Added a personal latency baseline, confirmed timeout incidents, fresh-session
  recovery verification, and non-stacking protection for timed-out requests.
- Kept Ollama, LM Studio, mlx_lm, and Osaurus as a complete second monitoring
  mode, with shared history, alerts, and diagnostics.
- Added two-mode onboarding, Apple health details, energy-aware scheduling, and
  explicit privacy and recovery explanations.
- Added per-runner pause, Keychain-backed bearer authentication, energy-aware
  inference scheduling, and automatic cleanup of probe-only Ollama residency.

## Screenshot sequence

1. **Know when local AI is actually working**: two-mode welcome with Apple
   Intelligence and Local AI Runners shown together.
2. **Private Apple Intelligence health**: healthy details with availability,
   response time, personal baseline, privacy, and recovery boundary.
3. **Catch inference wedges behind healthy HTTP**: configured Ollama details with
   the optional one-token check and resident-model context.
4. **Confirmed incidents, not noisy samples**: unified history containing Apple
   and runner examples with recovery duration.
5. **You control the checks**: Settings with functional cadence, alerts, login,
   and runner configuration.

Use real rendered application state. Do not show fabricated performance numbers
as if measured on the reviewer's Mac. Capture both light and dark appearances;
submit the clearer appearance for each story rather than duplicating every shot.

## Reviewer path

1. Launch on an eligible macOS 26 Mac with Apple Intelligence enabled.
2. Keep **Run private Apple Intelligence functional checks** enabled and choose
   **Start Monitoring**.
3. Open the menu and select **Run Functional Check**. Open Apple Intelligence
   Details to verify availability, completion time, baseline, privacy text, and
   recovery boundary.
4. Open Settings to disable functional checks and confirm availability-only mode
   remains useful.
5. Use the separately supplied HTTPS fixture to add the Local AI Runner review
   target, test connection and inference, and inspect runner Details.
6. Optionally enable notifications. Full Hearth pairing is not needed for review.

Review notes must include the fixture URL and exact runner kind/model only in App
Store Connect, never in this public repository.
