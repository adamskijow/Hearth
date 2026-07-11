<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor implementation audits

Each major addition passes four questions before the next begins:

1. **User experience:** can someone understand the state and next action without
   knowing Hearth's implementation?
2. **Product value:** does this make attached local-AI monitoring materially
   better than a generic uptime checker?
3. **Feature need:** is every capability necessary for that value, or is it
   speculative surface area?
4. **Bug and safety audit:** what can fail, what was tested, and what remains?

The full Hearth product is a protected constraint throughout: no App Store
sandbox requirement may reduce its managed-mode recovery behavior.

## Gate 1: separate sandboxed product boundary

### Addition

- Added a distinct `HearthMonitor` executable target depending only on
  `SupervisorCore`.
- Added a separate `com.hearth.HearthMonitor` app bundle and a minimal entitlement
  set: App Sandbox plus outbound network client access.
- Added local packaging and a mechanical boundary audit that rejects process,
  privilege, daemon, package-manager, and unsafe sandbox-exception capabilities.

### User-experience audit

The current shell is deliberately not a releasable interface. Its only text says
that the sandbox target is ready; it will not be presented as useful software
until it can discover or configure a runner and explain health. This avoids a
misleading early "green flame" that has not checked anything.

### Product-value audit

There is no end-user value yet, but the boundary is prerequisite value: it lets
Monitor reach the App Store without turning full Hearth into a restricted build.
Sharing only pure runner/status vocabulary also prevents the companion from
becoming a second, diverging implementation of runner protocols.

### Feature-need audit

- Outbound network access is required to probe local and remote runners.
- No network-server entitlement is present; Monitor does not need to expose a
  control surface.
- No file, automation, temporary-exception, root, or executable entitlement is
  justified, so none is present.
- A separate executable and app delegate are necessary. A runtime `appStore`
  switch inside full Hearth would be easier to accidentally bypass and harder to
  audit.

### Bug and safety audit

- `package-monitor-app.sh` builds and ad-hoc signs the app with the real sandbox
  entitlements; `codesign --verify --strict` passes.
- `audit-monitor-boundary.sh` verifies the bundle identifier, required
  entitlements, forbidden source capabilities, and absence of unsafe sandbox
  exceptions.
- A first audit run caught a rule that matched its own explanatory comment; the
  rule now matches actual imports/calls instead of prose.
- The selected Command Line Tools install briefly pairs a Swift 6.3.3 compiler
  with SDK interfaces emitted by 6.3.2. Packaging prefers the matching installed
  Xcode toolchain when available and has a macOS 15.4 SDK fallback for a truly
  CLT-only machine; normal CI selection remains untouched.
- A release build of full `Hearth` still succeeds after adding the target.
- Residual: an Apple Distribution archive, provisioning profile, and App Store
  upload validation still require the final packaging gate and credentials.

## Gate 2: attached monitor engine

### Addition

- Added `HearthMonitorCore`, a pure, separately tested library for monitor targets,
  discovery, snapshots, failure reasons, probe orchestration, and state reduction.
- Reused SupervisorCore's runner endpoint builders and response parsers through a
  narrowed API adapter; Monitor cannot request a process specification.
- Added conventional-port discovery for Ollama, LM Studio, mlx_lm, and Osaurus.
- Added shallow checks, optional one-token deep checks, slower model refreshes,
  busy handling, failure confirmation, and immediate verified recovery.

### User-experience audit

- The first failed check becomes **Checking** with the concrete provisional
  reason. A second consecutive miss becomes **Down**. This avoids both a false red
  status from one network hiccup and the dishonest choice of remaining green.
- HTTP 503 is **Busy**, a serving state, so Monitor never tells someone their
  active generation is an outage.
- A deep-probe failure explicitly says that the API answered but real inference
  failed. That distinction is the primary user value over a generic URL checker.
- Model-list parsing is supplementary. If it drifts, health stays green and a
  small metadata note explains what is unavailable.

### Product-value audit

The engine now contributes value a generic uptime utility does not: runner-aware
endpoints and models, queue-aware health, and inference-level wedge detection.
The failure-confirmation policy is useful for a continuously running menu app but
does not pretend to provide full Hearth's recovery powers.

### Feature-need audit

- Deep probing remains optional because it names and loads a model.
- Models refresh less often than health to reduce idle work and heat.
- Two failures is the default confirmation threshold; it is configurable for
  high-latency or unusually critical environments.
- Model management, request analytics, and arbitrary HTTP assertions remain out
  of scope. They would duplicate chat/model tools or generic uptime products.
- Discovery uses compatible endpoints at conventional ports. OpenAI-compatible
  runners cannot always identify their vendor, so onboarding must call those
  results candidates rather than claiming certainty.

### Bug and safety audit

- Fixed a provisional miss resetting the healthy-since timestamp even though no
  incident was confirmed.
- Fixed a deep-inference failure being allowed to recover on shallow HTTP alone;
  inference is now rechecked on every cycle until it passes.
- Fixed actor reentrancy allowing an old endpoint result to overwrite a target
  edited while the request was in flight. Target generations discard stale work.
- Collapsed overlapping timer and Check Now requests into one in-flight check.
- Fixed interpolated failure details that an early patch had rendered literally.
- Thirteen tests pass across state hysteresis, immediate recovery, busy behavior,
  resident models, noncritical metadata failures, deep failure/cadence/recovery,
  discovery, stale-result rejection, and overlapping-check collapse.
- Residual: the next gate must validate URLSession behavior under the actual App
  Sandbox and make ambiguous OpenAI-compatible discovery honest in the UI.

## Gate 3: first-run setup and Settings

### Addition

- Added a native first-run editor that scans conventional local ports, accepts a
  manual local or remote endpoint, supports HTTP and HTTPS, tests connectivity,
  reads the runner's model catalog, and explicitly tests one-token inference.
- Added a reusable Settings flow for adding, editing, selecting, and removing
  multiple watched runners.
- Added versioned JSON settings in the sandbox container with atomic writes and
  owner-only file permissions. Corrupt and future-version files are preserved
  and surfaced rather than silently replaced at launch.
- Added an ephemeral URLSession transport that refuses redirects and caps every
  response at 16 MB.

### User-experience audit

- Discovery results say **candidate**, not "detected LM Studio" or another claim
  the compatible HTTP response cannot prove. The user confirms the runner type.
- The first sentence says Monitor watches an existing runner and never starts,
  stops, or changes it. That prevents the App Store companion from being mistaken
  for full Hearth's recovery product.
- Wedge detection is opt-in and explains, before its button, that a one-token
  check can load the selected model into unified memory/GPU and that the runner
  controls residency. Model choices are deduplicated and sorted smallest first.
- A runner that is intentionally offline can still be saved, but only after an
  explicit unverified-settings confirmation. A verified badge is tied to the
  exact endpoint and model; editing either immediately asks for a retest.
- HTTP on a clearly remote-looking host gets an unencrypted-transport warning,
  while local/private HTTP remains uncluttered. HTTPS uses the same runner-aware
  paths rather than an unrelated generic URL field.
- A first-run scan that finds nothing ends with an actionable manual path instead
  of an error or an endless spinner.

### Product-value audit

The setup assistant makes inference-aware monitoring usable without asking the
user to know each vendor's readiness, catalog, and one-token request endpoints.
That guided model choice and verified deep check are meaningful differentiation
from a generic ping utility. Multi-runner configuration fits developers who use a
local desktop runner and a separate GPU host without adding process control to
the sandboxed product.

### Feature-need audit

- HTTP is retained for loopback and trusted LAN runners, which commonly ship
  without TLS; HTTPS is necessary for remote endpoints. Arbitrary URL assertions,
  custom request bodies, and headers remain out of scope.
- Saving an offline target is necessary for setup-before-start and intermittent
  remote hosts. It is a deliberate confirmation path, not the default happy path.
- Model catalog lookup and inference testing are present only to configure wedge
  detection. Model downloads, loading, unloading, and chat remain out of scope.
- Settings can hold multiple targets because the next gate monitors all of them;
  the selected ID only controls the primary presentation. No speculative groups
  or dashboards were added.
- Credentials are not stored in this gate. Authenticated pairing to full Hearth
  remains a separate, auditable capability rather than a generic secret field.

### Bug and safety audit

- Fixed HTTP-to-HTTPS edits failing to invalidate engine state, which could have
  shown a result from the old transport after Save.
- Fixed a slow successful setup test being able to verify fields edited while the
  request was in flight. Connection and inference results now carry exact input
  fingerprints.
- Fixed switching from discovery to a manual test leaving a cancelled discovery
  spinner active, and fixed a failed Settings selection write leaving an
  unpersisted row selected.
- Switching discovered endpoints clears a probe model chosen for the prior
  runner, preventing an accidental load attempt against the wrong server.
- Redirect refusal prevents a runner from replaying the inference POST to another
  host. Ephemeral sessions, no cache, standard TLS validation, bounded request
  time, and a response-size cap constrain the outbound trust boundary.
- Settings tests cover missing, corrupt, future-schema, permission, atomic
  round-trip, validation, and selection repair cases. UI-model tests cover stale
  verification and cancelled-operation state. Fixed-size render smoke tests cover
  both windows. Thirty-two Monitor tests pass in seven suites.
- The sandboxed release bundle launches and remains running with only App Sandbox
  and outbound network-client entitlements. Packaging and the expanded source
  boundary audit pass after scanning both `HearthMonitor` and
  `HearthMonitorCore`.
- Residual: configured targets are not scheduled yet, so the menu deliberately
  says **Configured** rather than claiming health. Live state, notifications,
  snooze, history, and diagnostics are Gate 4.

## Gate 4: live monitoring, alerts, history, and diagnostics

### Addition

- Added one independent, cancellable monitor loop per configured runner, an
  aggregate menu-bar state, per-runner menus, Check Now, and a native details
  window. Manual checks force the optional inference probe instead of merely
  repeating shallow HTTP.
- Added opt-in outage and recovery notifications, 30-minute/1-hour/4-hour/exact
  morning snooze choices, explicit resume, and Start at Login via `SMAppService`.
- Added a bounded 500-incident local history with active/recovered/monitoring-
  stopped resolution, inference classification, copied plain-text reports, and
  explicit repair for unreadable history.
- Added copied diagnostics covering endpoint, state, exact check time, deep-probe
  result, and resident models without capturing HTTP response bodies or logs.

### User-experience audit

- The menu-bar icon now communicates aggregate healthy, busy, checking, or down
  state. Each runner has a plain-language status, last-check age, resident models,
  inference verification, Check Now, and Details without turning the root menu
  into a dense dashboard.
- **Busy (serving)** is healthy during normal work. If a prior inference wedge is
  unresolved, the distinct **Busy (verifying recovery)** state avoids both a
  false red "not serving" claim and a false recovery.
- Notifications remain off until the user chooses them with context. Denial never
  disables monitoring or history. Snooze affects notifications only and displays
  its exact end time; an outage still active after snooze becomes alertable.
- One transient miss neither alerts nor enters history. A confirmed incident gets
  at most one outage alert and, only when that alert was delivered, one timely
  recovery alert.
- Details, History, Settings, and notification text all repeat the attached-only
  boundary: Monitor observes but cannot restart the runner. This is essential
  expectation-setting beside the full Hearth product.
- Start at Login is user-controlled and reports macOS approval or installation
  requirements instead of claiming registration succeeded.

### Product-value audit

This gate is the usable companion product: low-friction continuous state in the
menu bar, inference-aware incidents, resident-model context, quiet alert policy,
and a bounded evidence trail. The inference-only wedge path was exercised through
the signed App Sandbox build: `/api/version` continued returning HTTP 200 while a
real one-token POST hung; Monitor classified an inference incident and refused to
close it until one-token inference passed again. That is the core value generic
uptime utilities cannot provide.

### Feature-need audit

- Multi-runner loops fulfill the multi-target configuration already exposed;
  groups, remote dashboards, and analytics remain out of scope.
- Check Now forces inference because user intent justifies the GPU work; scheduled
  checks retain the slower configured cadence.
- Alerts, snooze, recovery, Start at Login, history, and clear diagnostics are the
  minimum dependable background-monitor workflow. Notification channels,
  arbitrary webhooks, log collection, and custom escalation rules remain out of
  scope for the App Store companion.
- History stores confirmed transitions rather than samples. It is capped at 500,
  writes at most once a minute during a long unchanged outage, and keeps active
  incidents when resolved history is cleared.
- Copy uses the pasteboard only on an explicit click, so no file entitlement or
  export workflow was added.

### Bug and safety audit

- Fixed a confirmed inference incident being falsely closed by a later shallow
  HTTP 503 or deep-probe 503. Busy now preserves the incident and retries real
  inference as soon as the runner accepts it.
- Fixed long outages causing a settings-style disk write on every check. Durable
  last-observed updates are throttled to one minute unless the diagnosis changes;
  live UI duration remains current.
- Alert delivery markers survive relaunch, concurrent delivery is collapsed, and
  a failed system delivery retries no more than every five minutes. Recovery
  retries expire after five minutes so an old recovery cannot appear days later.
- A corrupt history file is preserved and blocks automatic overwrite until the
  user explicitly chooses Reset History. Removing a down target records
  **monitoring stopped**, not a fabricated recovery.
- Disabled URLSession cookies and credential storage in addition to ephemeral
  sessions, redirect refusal, normal TLS validation, timeouts, and the 16 MB
  response cap. This prevents state leaking between multiple watched endpoints.
- Hardened settings against duplicate IDs, non-finite timing values, invalid host
  characters, control/newline menu labels, and unreasonable field lengths.
  Discovery now rejects unrelated HTTP 200 bodies while retaining honest
  compatible-endpoint wording for OpenAI-style runners.
- The signed sandboxed bundle made repeated shallow, model-list, and one-token
  calls to a real loopback fake runner. The inference-only wedge produced a
  persisted `inferenceLevel` incident with the expected cause and a later real
  inference success persisted `resolution: recovered`. The isolated container
  fixture was returned to clean first-run settings afterward.
- Fifty-five Monitor tests pass in thirteen suites. The complete repository passes
  422 tests in 70 suites; full Hearth still builds in release mode, retaining its
  managed GPU-wedge recovery path. The sandbox package, signature verification,
  expanded source-boundary audit, and whitespace audit all pass.
- Residual: automated validation deliberately did not grant system notification
  permission or register a login item on the user's account. Those system-facing
  interactions remain final installed-build checks.

## Gate 5: optional full Hearth recovery context

### Addition

- Added an optional authenticated `GET /status` connection from each watched
  runner to a separately installed full Hearth. Direct runner probes remain the
  health source; the bridge only adds supervisor mode, restart history, memory,
  thermal, and GPU/driver reboot-escalation context.
- Added named `controlStatusTokens` to full Hearth. These credentials can read
  `/status` and `/metrics`, receive HTTP 403 for start, stop, and restart, report
  their scope in the status document, and hide the browser control buttons.
- Added a guided pairing sheet that verifies the exact endpoint, token scope,
  and runner kind before Save. Monitor keeps the bearer token in its private
  Keychain item, never in its Codable settings or diagnostics.
- Added transactional connect, disconnect, target-removal, and settings writes so
  Keychain state is restored if the settings file cannot be committed.

### User-experience audit

- Pairing starts with **Optional** and explains that direct monitoring works
  without full Hearth. A successful status-only connection says **read-only**;
  an older or full-control credential requires a separate explicit consent
  toggle and recommends replacing it.
- The sheet tells the user exactly where to create a status-only token in full
  Hearth. The token editor can generate and explicitly copy the credential,
  avoiding error-prone manual selection of a long secret.
- Authentication failure, insufficient scope, timeout, unavailable host,
  incompatible response, missing Keychain item, and wrong-runner pairing have
  distinct next-action text. Editing any endpoint or token field invalidates the
  verified badge and requires a new test.
- HTTP bearer transport is warned unless it is loopback; the warning recommends
  HTTPS or an encrypted private overlay. Redirects remain refused, so the token
  is sent only to the exact configured `/status` URL.
- Recovery wording distinguishes full Hearth **managed** mode from
  **attached-only** mode. The audit fixed a misleading edge case where reboot
  escalation was configured in settings but inactive because full Hearth was
  attached-only.

### Product-value audit

This bridge preserves the product split instead of weakening it. The App Store
companion still detects a runner whose HTTP API responds while one-token GPU
inference is wedged. When the separate full product is installed, the same menu
also answers the next operational question: whether managed restart and optional
GPU/driver reboot recovery are actually covering that runner. Monitor observes
that coverage but never acquires the authority to perform it.

### Feature-need audit

- One read-only status request every 30 seconds is enough to present recovery
  coverage; streaming, remote commands, log retrieval, config mutation, and
  automatic installation of full Hearth remain out of scope.
- Status-only tokens are necessary least privilege because the existing control
  token authorizes process changes. Per-caller secrets allow independent
  revocation; diagnostics warn if a status credential reuses a control secret or
  if two status callers share one secret.
- Compatibility with older full Hearth status documents is retained, but saving
  a credential whose read-only scope cannot be proven requires explicit consent.
  This supports upgrades without silently weakening the preferred path.
- The bridge does not change incident classification, notifications, or the
  direct health state. A supervisor outage cannot turn a healthy runner red, and
  a healthy supervisor response cannot conceal a direct inference failure.

### Bug and safety audit

- The source boundary audit rejects any full-Hearth bridge POST or
  start/stop/restart path, bearer fields in Codable monitor core state, Keychain
  sharing groups, app groups, and unsafe sandbox exceptions.
- Authorization compares every configured bearer without early mismatch exit.
  Duplicate control/status secrets fail safely as full-control and are diagnosed
  as a configuration error; a status-only credential cannot downgrade an
  existing control credential by ordering.
- The pairing model rejects stale in-flight success, tokens outside reasonable
  bounds, incompatible runner kinds, and Save before exact verification. Status
  decoding is additive so older servers and future extra fields remain usable.
- A visual-audit bug was caught: SwiftUI `ImageRenderer` silently substituted
  unsupported AppKit controls with placeholder art while its tests passed. The
  smoke harness now captures the hosted views directly; onboarding, Settings,
  History, Details, and pairing render at their release sizes.
- Seventy-two focused tests pass across the bridge client/runtime/pairing, status
  authorization, config diagnostics and reload, stable status schema, and UI
  rendering. The latest release build packages and signs successfully, and the
  mechanical product-boundary audit passes.
- An initial Keychain implementation requested a data-protection Keychain mode
  that requires an entitlement not present in this private, non-sharing design.
  It was replaced with the standard macOS generic-password Keychain. The final
  signed App Sandbox executable passes a random write/read/delete self-test and
  retains no test credential. The test must run outside an enclosing automation
  sandbox; sandbox-on-sandbox execution aborts before Security returns an
  OSStatus, while the exact signed executable succeeds normally.
- Residual: the final gate must add App Store category/privacy/review metadata,
  distribution packaging instructions, installed accessibility/system checks,
  complete documentation, and the final whole-repository release run.

## Gate 6: App Store release readiness

### Addition

- Gave Hearth Monitor its own product identity, utility category, privacy manifest,
  privacy policy, local-network purpose string, help links, version, sandbox
  entitlements, and distinct flame-and-pulse icon. The package is a universal
  `arm64` and `x86_64` application and does not replace or modify full Hearth.
- Added a distribution script that validates the embedded App Store provisioning
  profile, derives the application identifier and team identifier entitlements,
  signs the nested executable and bundle, re-runs the product-boundary audit, and
  creates the signed installer package expected by App Store Connect.
- Added reviewer notes, release instructions, product documentation, and a
  privacy disclosure. CI now builds both products and packages the sandboxed
  Monitor boundary on every release check.

### User-experience audit

- The icon, app name, menu title, onboarding, and documentation consistently
  distinguish the read-only Store companion from full Hearth. Users are told
  before setup that Monitor detects outages but does not restart their runner.
- Onboarding, configured and empty Settings, incident History, live Details, and
  full Hearth pairing were captured from real hosted SwiftUI views at their
  release window sizes in light and dark appearances. Content fits without
  clipping, target rows remain visible, and the token is never rendered in a
  plain text control.
- Local Network denial, App Transport Security rejection, authentication failure,
  and unreachable endpoints now have different recovery guidance. Privacy and
  help are reachable from the app menu, and Cancel works with the standard Escape
  shortcut in setup sheets.
- The app remains useful with only a compatible runner endpoint. Notifications,
  launch at login, one-token inference checks, and full Hearth recovery context
  are progressive opt-ins rather than first-run requirements.

### Product-value audit

The Store product preserves the valuable part that a sandbox can honestly
deliver: direct API, model-list, and one-token inference monitoring, including the
case where a runner still answers HTTP while GPU inference is wedged. It adds
clear incident history and alerts without claiming process control. Full Hearth
remains the separate product for managed restart and optional GPU/driver reboot
recovery; its read-only status bridge lets Monitor show whether that protection
is active without weakening the Store boundary.

### Feature-need audit

- Universal Intel and Apple silicon support, a distinct identity, privacy
  disclosures, Store signing inputs, and reviewer guidance are release needs.
  They were included because they affect installability, trust, or review.
- Automatic runner installation, process discovery outside the container,
  privileged helpers, restart commands, logs, remote configuration, analytics,
  subscriptions, and cloud accounts were not added. None is required for the
  monitoring promise, and several would dilute the least-privilege Store design.
- A live compatible HTTPS review fixture is an operational submission need, not
  an app feature. It remains outside the repository so no test credential or
  public control surface is shipped in the product.

### Bug and safety audit

- The final source and entitlement audit rejects process control, privileged
  helpers, command routes, shared Keychain or app groups, temporary sandbox
  exceptions, and Codable bearer tokens. Code signing verification and the
  designated requirement both pass for the packaged app.
- The final signed executable passed a random private Keychain
  write/read/delete cycle outside the enclosing automation sandbox, and the
  credential was deleted. The app bundle contains both `arm64` and `x86_64`
  executable slices.
- Release validation exposed a split Command Line Tools compiler/SDK and Bash
  3.2 empty-array failures in the test and CI harnesses. The scripts now select
  the matching installed Xcode toolchain when needed, isolate build caches, and
  avoid optional-array expansion while preserving hosted SwiftPM sandboxing.
- Hosted Xcode 16.4 exposed missing `Sendable` annotations on its older
  UserNotifications SDK. The notifier remains main-actor isolated and imports
  that framework with `@preconcurrency`, preserving the same runtime behavior
  while compiling against both the oldest hosted and current SDK metadata.
- The staged release audit caught trailing whitespace in the new entitlement
  file and project-forbidden punctuation in previously untracked UI strings and
  docs. CI now checks working-tree, staged, and committed whitespace and includes
  untracked files in its punctuation lint, closing both false-green paths.
- Debug and release builds, the signed sandbox package, whitespace and source
  lints, the product-boundary audit, and all 437 tests in 74 suites pass. Full
  Hearth's managed GPU-wedge recovery tests remain green.
- Residual before an App Store submission: supply the Apple distribution
  certificate, installer certificate, and App Store provisioning profile; upload
  the resulting package through App Store Connect; provide the reviewer with a
  live compatible HTTPS fixture; and manually verify VoiceOver, notification
  authorization, login-item behavior, and the installed receipt build on a clean
  macOS account. These external checks are not represented as completed.
