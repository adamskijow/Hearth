<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor historical design decisions

Standalone Hearth Monitor was retired on September 7, 2026. These notes describe
the retained source, not an active roadmap. See [retirement and migration](hearth-monitor.md).

## Product boundary

- **Hearth** owns runner processes, performs recovery, keeps the Mac awake, and
  can escalate persistent GPU failures. It ships outside App Sandbox.
- **Hearth Monitor** observes attached runners and Apple's on-device language
  model. It ships as a separate sandboxed executable.

`scripts/audit-monitor-boundary.sh` checks dependencies and entitlements. Store
requirements cannot weaken full Hearth recovery.

## Health model

A responsive API may hide failed inference. Monitor combines a lightweight API
check with an optional one-token generation for Ollama, LM Studio, `mlx_lm`, and
Osaurus.

One failure enters verification; a second opens an incident. Inference incidents
close after successful inference. Busy responses remain serving states. Monitor
keeps process ownership with the runner's existing manager.

## Apple model

On compatible Macs, Monitor reads Foundation Models availability and can request
one fixed on-device response with user consent. It stores timing, health, and
bounded incident data. Siri, Writing Tools, image generation, and other Apple
Intelligence features fall outside this check.

Timed-out work remains tracked until completion, preventing overlapping requests.
Automatic checks pause for sleep, Low Power Mode, and serious thermal pressure.
macOS owns service recovery; Monitor can refresh only its app session.

## Privacy and credentials

Monitor has no analytics or developer service. Requests travel directly to user
configured endpoints. Tokens use separate Keychain items and stay out of settings,
history, and diagnostics. Responses are size-bounded; redirects and shared web
credential state are disabled.

Optional full Hearth pairing uses a status-only token and `GET /status`. It adds
recovery context while direct checks remain the health source.

## Historical scope

Monitor reports current health, recent checks, and bounded incidents. It avoids
lifetime reliability claims unsupported by retained data.

## Historical release evidence

Monitor candidates used shared tests, universal packaging, the sandbox boundary
audit, UI renders, Keychain and Apple model self-tests, and runner checks.
Distribution procedures are retained in the tagged source. Publication is now
disabled; local archive packaging and auditing are opt-in through
`scripts/ci.sh --legacy-monitor`. Machine dogfood logs stay local.

## Historical review questions

1. Can a user understand the state and next action?
2. Does the feature improve inference-aware monitoring?
3. Is the added surface justified by measured value?
4. What failure evidence covers it?
5. Can it cross full Hearth's process-control boundary?
