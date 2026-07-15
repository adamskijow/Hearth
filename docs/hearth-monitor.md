<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor

Hearth Monitor is a private, sandboxed menu-bar health monitor for two kinds of
local AI:

- **Apple Intelligence**: zero-setup availability plus an optional tiny
  functional response that proves Apple's on-device system model can complete a
  request.
- **Local AI Runners**: attached monitoring for Ollama, LM Studio, `mlx_lm`, and
  Osaurus, including optional inference-level checks that catch a runner whose
  HTTP API answers while generation is wedged.

Both modes share confirmed incident history, notifications, diagnostics, and
energy safeguards. Monitor never starts, stops, installs, updates, or changes a
runner, and macOS does not let it restart Apple's private model service.

The separate full **Hearth** product remains the choice when you need automatic
runner restart, keep-awake behavior, and optional GPU/driver reboot recovery.
Monitor works without full Hearth; an optional read-only connection can show
whether full Hearth is providing that recovery.

## Requirements

- macOS 14 or later on Apple silicon or Intel for Local AI Runner monitoring.
- Apple Intelligence monitoring requires macOS 26 or later, an eligible Mac,
  and Apple Intelligence enabled. Unsupported Macs still get the complete
  runner mode.
- Runner mode requires a reachable Ollama, LM Studio, `mlx_lm`, or Osaurus
  server on this Mac, a private network, or an HTTPS address you control.
- Local Network permission when macOS asks. Declining it does not expose any
  data, but local and LAN runners cannot be reached until permission is enabled
  in System Settings.

## Monitor Apple Intelligence

On first launch, choose whether to enable private functional checks. Passive
availability monitoring only reads the public Foundation Models state. A
functional check asks the on-device model for one tiny fixed response, discards
the response immediately, and stores only status and timing metadata.

Scheduled functional checks default to 15 minutes apart. They pause while the
Mac sleeps, in Low Power Mode, or under serious thermal pressure. Hearth requires
two failed checks before recording an incident or notifying you. If a request
times out, it is retained until it actually finishes and Hearth refuses to stack
another request behind it.

Apple status remains specific:

- **Available:** the public framework is ready; functional checks are off.
- **Healthy:** a functional response completed.
- **Responding slowly:** it completed at least three times slower than this
  Mac's recent baseline and took at least eight seconds. Slow is not an outage.
- **Verifying a possible stall:** one functional check failed or timed out.
- **Not responding:** the configured number of functional checks failed.
- **Apple Intelligence is off / Model not ready / Mac not eligible:** an
  availability condition, not a fabricated wedge.

Hearth creates a fresh app session for each functional check. A successful fresh
session can verify app-level recovery, but Hearth cannot kill or restart Apple's
OS-owned service and never claims it did.

## Set up a Local AI Runner

1. Open Hearth Monitor. It appears in the menu bar rather than the Dock.
2. Choose a compatible local candidate, or enter the runner type, host, and port.
3. Select HTTP for loopback or a trusted private network. Prefer HTTPS elsewhere.
4. If a reverse proxy protects the runner, enable bearer authentication and
   enter its credential. The credential is stored only in the login Keychain.
5. Choose **Test Connection**. You can still save a temporarily offline address
   after confirming that it is unverified.
6. Optionally enable **Run a one-token inference check**, choose a small model,
   select a cadence, and test it. The default is five minutes. For Ollama, a
   model loaded only for an automatic check is unloaded immediately afterward;
   a model that was already resident keeps its normal residency policy.

The default scheduled API check is frequent and lightweight. The optional
one-token check runs more slowly, pauses during sleep, Low Power Mode, and serious
thermal pressure, and is staggered across runners. **Check All Now** checks
runners sequentially so canaries do not fight for one GPU. A user-requested check
intentionally overrides the energy deferral and verifies real inference rather
than only HTTP.

## Read the status

- **Healthy:** the runner API answers; the last scheduled inference check also
  passed when wedge detection is enabled.
- **Busy (serving):** the runner reports that it is handling work. This is not
  an outage.
- **Checking:** the first check is running, or one transient miss is being
  confirmed. A single miss never creates an incident.
- **Down:** repeated API checks failed, or a one-token inference check failed.
- **Busy (verifying recovery):** the API is serving work after a confirmed
  inference failure, but Monitor has not yet observed successful inference.
- **Paused:** this runner performs no checks or full Hearth polling until you
  turn **Monitor this runner** back on. Pausing closes any open incident as
  monitoring stopped, not recovered.

Use the Apple Intelligence and runner submenus for exact reasons, last checks,
timing or resident models, **Check Now**, and **Details**. The root icon
summarizes both modes, with a confirmed failure taking priority.

## Alerts, history, and login

Outage notifications are off by default. Enable them from the menu or Settings;
macOS asks for permission with that context. Snooze suppresses notifications only:
health checks and incident history continue, and an outage still active after the
snooze can alert then. A recovery notification is sent only when its outage alert
was delivered recently.

History contains confirmed Apple or runner incidents rather than samples, is
capped at 500, and stays on this Mac. Removing a down target records **monitoring
stopped**, not a false recovery. Pausing has the same honest incident boundary
without deleting the configuration. **Open at Login** is also opt-in and uses
macOS's Login Items API.

## Show full Hearth recovery status (optional)

On the Mac running full Hearth:

1. Open full Hearth **Settings → Remote control** and enable its endpoint.
2. Open **Status-only tokens**, add a token named `hearth-monitor`, generate a
   unique secret, and copy it.
3. In Hearth Monitor, open the watched runner's submenu and choose **Connect Full
   Hearth…**. Enter the status endpoint and paste the token.
4. Choose **Test Read-Only Connection**, then Save.

Monitor authenticates only `GET /status`. A current status-only token receives
HTTP 403 for start, stop, and restart. The token stays in Monitor's private macOS
Keychain item and is removed when you disconnect or delete the target. An older
full Hearth version or broader token requires explicit consent because Monitor
cannot prove least privilege.

The recovery card reports whether full Hearth is managed or attached-only. It
does not change direct health: a full Hearth outage cannot make a healthy runner
red, and a healthy supervisor cannot conceal failed inference.

## Security and privacy

Hearth Monitor has only App Sandbox and outbound network-client entitlements. It
has no process-control, file-access, automation, root, daemon, incoming-network,
app-group, or Keychain-sharing entitlement. Redirects are refused, HTTP sessions
are ephemeral, cookies and shared credentials are disabled, and response bodies
are bounded.

The app contains no analytics, ads, tracking, account, or third-party SDK and
sends no data to the developer. The Apple canary prompt and response are never
persisted; only availability, timing, broad failure category, and incident state
are retained. Settings and history stay in its sandbox container; optional runner
and full Hearth credentials stay in separate Keychain items. See the
[privacy policy](../PRIVACY.md).

## Troubleshooting and removal

- **No candidate found:** start the runner, verify its port, or enter the address
  manually. A compatible OpenAI-style endpoint cannot always identify its vendor,
  so confirm the runner type.
- **Connected, inference failed:** verify the model name and that it fits memory.
  This can also be the wedge Monitor is designed to catch.
- **Apple Intelligence is off:** enable it in System Settings. This is an
  availability state and does not create a timeout incident.
- **Model not ready:** let macOS finish downloading or preparing its model, then
  use **Check Now**. Hearth does not repeatedly generate while assets are absent.
- **Persistent Apple timeout:** Hearth avoids overlapping canaries. If the same
  retained request remains alive for another timeout window, that continuing
  stall confirms the incident without launching a second request. macOS owns
  further recovery; save the diagnostic report before rebooting or updating the
  system.
- **Inference check deferred:** wake the Mac, turn off Low Power Mode, or let
  thermal pressure ease. **Check Now** remains available when you deliberately
  want an immediate check.
- **Bearer credential missing or rejected:** edit the runner and paste a current
  credential. Hearth does not silently retry the endpoint without authentication.
- **HTTP warning:** use HTTPS unless the endpoint is loopback or carried by an
  encrypted private overlay such as Tailscale.
- **Full Hearth token rejected:** create a fresh status-only token and test the
  exact status host/port again.
- **No notifications:** allow Hearth Monitor in System Settings → Notifications.
- **Login item needs approval:** allow it in System Settings → General → Login
  Items. Monitoring still works whenever the app is open.

Remove a watched runner from Settings and clear resolved History as desired.
For complete local-data removal, quit the app and delete
`~/Library/Containers/com.hearth.HearthMonitor`. This does not change or remove
any AI runner or full Hearth installation.
