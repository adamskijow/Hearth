<!-- SPDX-License-Identifier: MIT -->
# Running headless

The menubar agent needs a logged in desktop session. For a Mac where nobody logs
in, Hearth has a headless mode that runs supervision with no GUI: no menubar and
no local Notification Center (there is no session to show it), but ntfy still
reaches your phone, and the control endpoint and the power assertion work the
same.

```
hearth --headless          # or set HEARTH_HEADLESS=1
```

## Keep it running at login (one command)

The easy way to run Hearth headless and keep it alive is a per-user login agent,
installed in one step (no sudo):

```
hearth install-agent
```

This writes `~/Library/LaunchAgents/com.hearth.headless.plist` pointing at the
Hearth binary you ran it from and your config, then loads it with `launchctl`.
Hearth now starts headless at login and is kept alive. Remove it any time with
`hearth uninstall-agent`.

It is safe to run even if the menubar app also launches at login: the
single-instance guard means whichever starts first supervises and the other stands
by, so they never fight. This is the recommended setup for an app that depends on a
local runner staying up. Such an app does not integrate with Hearth's API; it
depends on the runner directly and gates its own startup on the runner answering:

```
hearth wait-ready && my-app   # start once the runner actually answers
```

The full contract (what to do, what not, graceful degradation, the Hob example) is
in [Integrating with Hearth](integrating.md).

## Before anyone logs in (root daemon)

A login agent only runs once you are logged in. To run Hearth before any login (a
Mac in a closet that reboots unattended), install it as a root LaunchDaemon. The
files are in `deploy/` and the installer is `scripts/install-daemon.sh`. It
modifies your system (writes to `/usr/local/bin`, `/etc/hearth`, and
`/Library/LaunchDaemons`), so read it first and run it with sudo:

```
swift build -c release
sudo ./scripts/install-daemon.sh
# if the installer reports doctor errors, edit
# /etc/hearth/config.json (set runnerUser and your tokens), then:
sudo hearth doctor-daemon
sudo launchctl bootstrap system /Library/LaunchDaemons/com.hearth.daemon.plist
```

Remove it with `sudo ./scripts/uninstall-daemon.sh`. In daemon mode Hearth runs
as root, so its config lives at `/etc/hearth/config.json` (pointed to by the
plist's `HEARTH_CONFIG`) and its logs at `/var/log/hearth.out.log` and
`/var/log/hearth.err.log`. Managed mode in the root daemon requires `runnerUser`,
an unprivileged local account that runs the LLM runner while Hearth itself keeps
root only for launchd and optional reboot recovery. If your models live outside
that account's home directory, set `runnerEnv.OLLAMA_MODELS` to the model
directory.

The installer runs `sudo hearth doctor-daemon` before starting the daemon. If the
doctor reports errors, the installer leaves the daemon stopped so you can fix the
config or stop a competing runner first. Warnings are printed but do not stop
startup, because some warnings are intentional setups such as LAN binding or
attached mode before the runner is serving. After editing the config, run
`sudo hearth doctor-daemon`; when it has no errors, bootstrap the daemon with
`sudo launchctl bootstrap system /Library/LaunchDaemons/com.hearth.daemon.plist`.
For later config changes on a loaded daemon, apply them by restarting it with
`sudo launchctl kickstart -k system/com.hearth.daemon` (it has no in-process live
reload; the runner cycles briefly), or send SIGHUP (`sudo launchctl kill HUP
system/com.hearth.daemon`), which stops it cleanly and lets launchd respawn it with
the new config. To check the daemon config specifically, run:

```
sudo hearth doctor-daemon
```

## Recovering a wedge a restart cannot

Killing and respawning the runner clears a process-level wedge. Some hangs are at
the driver or GPU level and survive a process restart; only a reboot of the Mac
clears them (see [Known limitations](limitations.md)). On a headless box you would
otherwise have to notice and reboot it by hand. The recovery ladder closes that gap
as an opt-in last resort:

```
probe readiness
  wedged?           -> kill and respawn the runner group   (clears most wedges)
  still wedged long
  after restarts
  stopped helping?  -> reboot the Mac -> comes back, respawns the runner clean
```

Enable it in the config. It is off by default and needs Hearth running as root
(the headless daemon above), because rebooting takes privileges:

```json
{ "rebootOnWedge": true }
```

### Experimental: the least-privilege split

Running the whole supervisor as root exists only because of that one reboot.
`hearth-reboot-helper` inverts it: a tiny root LaunchDaemon whose entire API is
"reboot, if you are the configured uid and not too often", offered on a
root-owned unix socket (mode 600, chowned to the allowed uid, with the peer
re-verified on every connection and a rate limit enforced in the helper
itself). With it installed, a NON-root headless Hearth keeps the full recovery
ladder:

```
sudo ./scripts/install-reboot-helper.sh     # builds and installs the helper
# then, in the non-root daemon's config:
{ "rebootOnWedge": true, "rebootViaHelper": true }
```

The helper logs to `/var/log/hearth-reboot-helper.log` and is removed with
`scripts/uninstall-reboot-helper.sh`. Experimental: the classic root daemon
remains the documented default while this soaks.

The policy is deliberately paranoid, because an auto-reboot done wrong is a boot
loop:

- Off by default; nothing reboots unless you opt in.
- Only after the runner was actually healthy this session. A wrong binary path or
  a bad config never triggers a reboot, only a runner that was serving and then
  wedged past what a restart can fix.
- Only after a sustained failing streak (`rebootEscalateAfterSeconds`, default ten
  minutes), so a brief blip never reboots.
- Loop-protected. The reboot history is persisted across the reboots themselves;
  if a reboot did not help (still wedged sooner than `rebootMinIntervalSeconds`)
  or the daily cap (`rebootMaxPerDay`) is reached, Hearth stops and notifies you
  rather than rebooting again.
- Loud. ntfy fires before the reboot, and again if it gives up.

A reboot cannot fix a hardware or thermal fault, so the give-up-and-notify path is
the honest floor: if even a reboot does not restore the runner, a human needs to
look.
