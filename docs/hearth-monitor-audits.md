<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor design decisions

This document records the durable product and safety decisions behind Hearth
Monitor. Transient implementation notes, machine-specific observations, test
counts, and release status belong in commits, CI, and release records instead.

## Product boundary

Hearth has two deliberately separate Mac products:

- **Hearth** is the full Developer ID product. It can own a runner process,
  recover crashes and inference wedges, preserve GPU-native operation, and use
  optional reboot escalation. These capabilities require operation outside App
  Sandbox.
- **Hearth Monitor** is the Mac App Store product. It observes user-configured
  local AI runners and Apple's on-device language model without controlling a
  runner or a system service.

Monitor is a separate executable and sandboxed bundle, not a runtime mode inside
full Hearth. Its dependency and entitlement boundary is mechanically checked by
`scripts/audit-monitor-boundary.sh`. Store requirements must never weaken full
Hearth's recovery behavior.

## Core user value

A responsive HTTP endpoint does not prove that inference is working. Monitor can
therefore combine a lightweight API check with an optional tiny inference check.
This distinguishes an available runner from a runner whose API answers while
generation is wedged.

Monitor supports Ollama, LM Studio, mlx_lm, and Osaurus in attached mode. It can
show health, resident models, confirmed incidents, and actionable next steps. It
never starts, stops, installs, updates, or restarts these runners.

One transient failure is shown as a pending check. A second consecutive failure
is required to open an incident or alert. A successful inference check is
required to close an inference incident; a shallow HTTP success is insufficient.
Busy responses remain serving states and do not trigger recovery claims.

## Apple on-device model

On compatible Macs, Monitor uses Apple's public Foundation Models framework to
check availability and, with explicit user consent, request one tiny fixed local
response. It immediately discards the response and retains only health, timing,
and bounded incident information.

The check covers Foundation Models language generation. It does not claim to
verify Siri, Writing Tools, image generation, or every Apple Intelligence
feature. Monitor can recreate its own session, but macOS owns the underlying
model service and Monitor never claims to restart it.

Timed-out work is retained rather than abandoned and stacked behind another
request. Automatic checks pause for sleep, Low Power Mode, and serious thermal
pressure. Explicit checks remain available when the user requests them.

## Privacy and credentials

Monitor has no analytics or developer-operated service. Runner requests travel
directly between the Mac and endpoints the user configures. Apple model prompts
and responses remain on device. Settings and diagnostics never contain bearer
tokens.

Optional runner credentials and full Hearth status credentials use distinct
Keychain items. A missing credential fails explicitly. Network responses are
size bounded, redirects and shared credential state are restricted, and copied
diagnostics describe configuration and recovery scope without exposing secrets.

## Optional full Hearth context

Monitor can pair with a separately installed full Hearth through a status-only
credential. It verifies the endpoint, runner identity, and credential scope,
then displays whether managed recovery is present. It does not send start, stop,
restart, or configuration commands.

This integration is supporting context, not a prerequisite or the primary
Monitor workflow. Unpaired users keep the complete Apple and attached-runner
monitoring experience.

## Deliberate scope limits

The private Model Lab experiment was removed. A generic prompt playground added
surface area without improving the core promise of detecting failed local
inference or explaining recovery coverage. Reintroducing arbitrary prompts,
sampling controls, streaming, or token accounting requires new evidence that
they materially improve monitoring or recovery outcomes.

Monitor also avoids invented uptime percentages and lifetime success counts. It
shows only evidence it actually retains: current health, recent verified checks,
bounded incidents, and relevant runner or model context.

## Release evidence

A release candidate must pass the complete shared test gate, both product
builds, universal Monitor packaging, the App Store capability boundary audit,
and release-sized UI renders. Distribution builds also require signed Keychain
and Apple model self-tests, a real inference-aware runner check, and TestFlight
review before App Review.

Machine-specific dogfood logs remain local and are never committed. A release
record should distinguish automated coverage, one-machine functional evidence,
and behavior that still requires external review. Passing one does not imply the
others passed.

## Review questions for future changes

Every material Monitor addition must answer:

1. Can a user understand the state and next action without knowing Hearth's
   implementation?
2. Does it improve inference-aware monitoring rather than duplicate a generic
   uptime checker or model playground?
3. Is the feature necessary for that value, or is it speculative surface area?
4. What can fail, what evidence covers it, and can it affect full Hearth's
   process-control boundary?
