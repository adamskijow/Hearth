<!-- SPDX-License-Identifier: MIT -->
# Running headless

Headless mode runs supervision without a menu bar or Notification Center. ntfy,
webhooks, heartbeat, the control endpoint, and the power assertion remain
available.

```sh
hearth --headless
```

`HEARTH_HEADLESS=1` is equivalent.

## Start after login

Install the per-user LaunchAgent:

```sh
hearth install-agent
```

It writes `~/Library/LaunchAgents/com.hearth.headless.plist` and keeps Hearth
running after login. Remove it with `hearth uninstall-agent`. The single-instance
guard coordinates it with the menu-bar app.

Dependent apps can wait for the runner:

```sh
hearth wait-ready && my-app
```

See [Integrating with Hearth](integrating.md).

## Start before login

Install the root LaunchDaemon for an unattended Mac:

```sh
swift build -c release
sudo ./scripts/install-daemon.sh
```

The installer writes `/usr/local/bin`, `/etc/hearth`, and
`/Library/LaunchDaemons`; inspect it before use. Logs go to
`/var/log/hearth.out.log` and `/var/log/hearth.err.log`.

Managed mode requires `runnerUser`, an unprivileged local account used for the
runner process. Set `runnerEnv.OLLAMA_MODELS` when its models live outside that
account's home directory.

The installer runs `doctor-daemon` and starts the daemon only if there are no
errors. If it reports **Installed but not started**, fix `/etc/hearth/config.json`
and any competing runner manager, then run:

```sh
sudo hearth doctor-daemon
sudo launchctl bootstrap system /Library/LaunchDaemons/com.hearth.daemon.plist
```

For a daemon already loaded, apply later config changes with:

```sh
sudo hearth doctor-daemon
sudo launchctl kickstart -k system/com.hearth.daemon
```

Remove the daemon with `sudo ./scripts/uninstall-daemon.sh`.

## Recovering a wedge a restart cannot

Some GPU or driver failures survive a runner restart. The root daemon can reboot
after a sustained failed-recovery streak:

```json
{ "rebootOnWedge": true }
```

Safeguards include prior healthy service in the current session, a ten-minute
default escalation delay, a minimum interval between recovery reboots, a daily
cap, persisted history, and alerts before reboot or give-up. Configure these with
`rebootEscalateAfterSeconds`, `rebootMinIntervalSeconds`, and `rebootMaxPerDay`.

## Experimental reboot helper

The helper lets a non-root Hearth request the final reboot step from a small root
daemon:

```sh
sudo ./scripts/install-reboot-helper.sh
```

```json
{ "rebootOnWedge": true, "rebootViaHelper": true }
```

Installation authorizes the Developer ID-signed Hearth binary at
`/Applications/Hearth.app/Contents/MacOS/Hearth`. Each request must match the
configured executable path, code requirement, user ID, audit token, and rate
limit. Development signatures are rejected. Set `HEARTH_HELPER_CLIENT` during
installation for another signed path.

Logs go to `/var/log/hearth-reboot-helper.log`. Remove the helper with
`scripts/uninstall-reboot-helper.sh`.
