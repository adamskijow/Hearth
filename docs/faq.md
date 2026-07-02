<!-- SPDX-License-Identifier: MIT -->
# FAQ

Plain answers to the questions people have before and just after installing.
The [README](../README.md) has the tour; [Troubleshooting](troubleshooting.md)
has the fixes.

## Is Hearth for me?

If you run models locally with Ollama (or LM Studio or mlx_lm) and you want them
to stay up without babysitting (for a chat app you use daily, a home-lab server,
or anything that talks to `localhost:11434`), yes. Hearth restarts the runner
when it crashes, notices when it is running but no longer answering, keeps the
Mac awake while it serves, and alerts you when something breaks.

Hearth is not a chat UI, does not run models itself, and does not install or
download models. It stands behind the runner you already use.

## Does it work on a normal Mac, or only a server?

Any Mac running macOS 14 or later: a desktop, a Mac mini in a closet, or a
laptop. The docs sometimes say "headless," which just means a Mac nobody is
logged into at the moment, not a special kind of machine. One thing to know on
a laptop: while the runner is serving, Hearth deliberately keeps the Mac from
idle-sleeping, which uses battery if it is unplugged.

## I use the official Ollama app. What do I do?

Install Hearth normally. The Ollama app starts its own server, and Hearth will
notice that and offer a one-click fix in its menu ("Watch the Existing Runner
Instead") so Hearth watches the app's server rather than starting a second one.
That is attached mode; details in the [Ollama setup guide](ollama.md).

## What do "managed" and "attached" mean?

The two words that appear in the config and CLI, in plain terms:

- **Managed:** Hearth starts the runner and restarts it when it fails. The
  default, and what you want if nothing else starts Ollama for you.
- **Attached:** something else starts the runner (the Ollama app, `brew
  services`), and Hearth only watches it and alerts you. In this mode Hearth
  never starts or stops the runner itself.

The Preferences window calls these "Hearth starts runner" and "Watch existing
runner"; they are the same two settings.

## How do I know it is working?

Three checks, any one is enough:

1. The menubar flame has no warning badge, and clicking it shows **Healthy**.
2. `hearth status` in Terminal shows the health, uptime, and loaded models.
3. `hearth doctor` in Terminal ends with `0 errors, 0 warnings.`

To see it actually save you: quit Ollama however you like, and watch Hearth
bring it back.

## What happens when the runner crashes?

Hearth notices within seconds, sends a "Runner down" notification, and restarts
it. If it keeps failing, Hearth waits a little longer between each attempt, and
after several rapid failures it slows right down (the menu says "Crash loop")
and keeps retrying until the underlying problem clears; it never just gives up
silently. [Troubleshooting](troubleshooting.md) covers reading the log when
that happens.

## Do I have to change my apps or models?

No. Your apps keep talking to the runner at the same address they always have;
several apps and models share the one runner. Hearth changes nothing about how
inference works; it only keeps the server process alive.

## Does Hearth send my data anywhere?

No. Prompts, model output, and models never leave the machine through Hearth.
The only things it ever sends are the short status alerts you explicitly
configure (macOS notifications, an ntfy topic for your phone, or a webhook),
and those contain status text like "Runner down", nothing more.

## Do I need ntfy, Tailscale, or the "control endpoint"?

No; all three are optional extras for checking on a Mac you are away from. The
control endpoint is a small password-protected status page you can open from a
phone; ntfy pushes alerts to a phone; Tailscale is one safe way to reach either
from outside your home network. A single Mac you sit at needs none of them.

## Can Hearth supervise two runners at once (Ollama and mlx, say)?

Yes, with two Hearth instances: one per runner, each with its own config. The
single-instance lock is keyed to the config file, so two configs coexist:

```
HEARTH_CONFIG=~/.config/hearth-mlx.json hearth --headless
```

Give the second config its own `runner`, `port`, and (if enabled)
`controlPort`. Each instance supervises, alerts, and serves status for its own
runner; there is no cross-runner orchestration, by design.

## I am going on vacation. Can I quiet the alerts without losing my setup?

Yes: Pause Notifications in the menu (or `"notificationsPaused": true` in the
config) silences local, ntfy, and webhook alerts without touching their
settings. Hearth keeps supervising and logging events; unpause when you are
back.

## My Mac runs with nobody logged in. Does Hearth still work?

Yes, that is its favorite habitat. `hearth setup` installs a login agent so
Hearth starts at login, and [Running headless](running-headless.md) covers the
fully unattended setup (starting before login, and the optional
reboot-as-last-resort recovery).

## How do I uninstall it?

```
brew uninstall --cask hearth
```

Add `--zap` to also delete Hearth's config and logs. If you installed the
headless extras, `hearth uninstall-agent` removes the login agent first. Ollama
and your models are untouched.
