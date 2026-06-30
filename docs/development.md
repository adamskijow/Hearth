<!-- SPDX-License-Identifier: MIT -->
# Development

Working on Hearth: running the test suite and cutting a release. For the
configuration reference see [configuration.md](configuration.md); for embedding
Hearth in an app that depends on a local runner see [integrating.md](integrating.md).

## Testing

`SupervisorCore` is covered by a Swift Testing suite driven entirely by fakes for
the clock, process control, and HTTP. There is no real runner and no real
`sleep`; the fake clock is advanced by hand. The suite covers readiness catching
a hung but alive runner, exponential backoff timing, a crash loop entering the
failing state without thrashing, recovery back to healthy, out of memory versus
crash classification, attached mode never spawning or killing, the runners' spec
and parsing (including a real Ollama `/api/ps` capture), the pre-spawn process
group sweep, the hard-crash sweep decision, log rotation decisions, the control
endpoint's routing and auth, the metrics formatting, tailnet address recognition,
runner binary location ordering, config resolution (the first-run, clean, and
parse-failure paths), the status line wording for every phase, the readiness
mapping from each HTTP outcome, and the exit and down-reason labels.

For end to end checks against a live server, `scripts/validate-real.sh` drives the
real agent against a real `ollama serve` and proves the lifecycle scenarios
(cold start, external kill, the SIGSTOP wedge, process group teardown with no
orphans, attached mode, and hard-crash orphan recovery), exiting non-zero on any
failure. It needs a real Ollama; its findings and the fix it drove are written up
in [VALIDATION-REPORT.md](../VALIDATION-REPORT.md).

Run the tests with:

```
make test
```

or directly:

```
./scripts/test.sh
```

The wrapper exists because the tests use Swift Testing, and on a Mac with only
the Command Line Tools installed (the common state on a headless box) the Swift
Testing framework is not on the default search path. The script detects the right
directory for both the Command Line Tools and full Xcode layouts and passes it.
On a machine with full Xcode, a plain `swift test` also works.

The gate runs in two places, both through `scripts/ci.sh`: locally via the
pre-push hook, and on GitHub Actions (free for public repositories) for every push
and pull request (`.github/workflows/ci.yml`). `make ci` (or `./scripts/ci.sh`)
builds debug and release, runs the unit suite, and lints (an SPDX header on every
Swift source, and the no em dash rule). Install the pre-push hook once with
`make hooks`, which points `core.hooksPath` at the in-repo `scripts/hooks`, and
that gate runs before every push; bypass a single push with `git push
--no-verify`. Pass `--smoke` or `--real` to `scripts/ci.sh` to also run the
desktop and Ollama gates described below.

### Trying it without a runner

You can exercise the whole agent without installing Ollama or LM Studio, using a
small stand in runner that answers the endpoints Hearth probes:

```
./scripts/smoke-test.sh
```

This builds Hearth, points it at `scripts/fake-runner.py` through a throwaway
config, and checks the acceptance behavior end to end: the agent starts and owns
the child, holds the power assertion (`pmset`), restarts the child when it is
killed externally, drives a restart through the control endpoint (with token auth
checked), and releases the assertion and kills the child on a clean shutdown. It
launches the real menubar agent, so it needs a logged in desktop session; it is a
local helper, not a CI step.

For the wedge-recovery story specifically:

```
make demo
```

drives the same fake runner through the alive-but-wedged case: it reaches healthy,
freezes the runner with `SIGUSR1` (the process stays up and the port stays open,
but it stops answering), and narrates Hearth catching it by readiness and recovering
on its own. It is fully isolated through `HEARTH_DATA_DIR` (its state, logs, and
lock live under a throwaway directory), so it is safe to run alongside a real
Hearth. It is the source for the README's wedge-recovery recording.

## Releasing

`scripts/release.sh` builds, Developer ID signs (Hardened Runtime on, App Sandbox
off), notarizes, and staples `Hearth.app`, then packages it two ways: a
drag-to-install DMG (`scripts/make-dmg.sh`, the app plus an Applications shortcut)
and a zip, notarizing and stapling the DMG as well. It prints the sha256 of each.
It needs a signing identity and notarization credentials, either a stored
notarytool profile:

```
export HEARTH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export HEARTH_NOTARY_PROFILE="HearthNotary"   # from xcrun notarytool store-credentials
./scripts/release.sh
```

or an App Store Connect API key passed directly, which works in a non-interactive
shell where storing a keychain profile is blocked:

```
export HEARTH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export HEARTH_NOTARY_KEY="$HOME/path/AuthKey_XXXX.p8"
export HEARTH_NOTARY_KEY_ID="XXXX"            # the XXXX in the filename
export HEARTH_NOTARY_ISSUER="<issuer-uuid>"   # App Store Connect issuer ID
./scripts/release.sh
```

Releasing can be local: run it on your Mac, attach the DMG (and zip) to a GitHub
release, then set `Casks/hearth.rb` `version` and `sha256` to the DMG's. Once
published from a tap, install with `brew install --cask adamskijow/tap/hearth`.
For a quick local install without a release, `make install` ad-hoc signs and
copies the app to `/Applications`.

It can also be hosted: pushing a `v*` tag runs `.github/workflows/release.yml`,
which gates on CI and, when the signing secrets are configured (the workflow
header lists them), signs, notarizes, and publishes the release automatically.
Without those secrets the tag still gets a release gate and you publish locally.
