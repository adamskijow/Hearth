<!-- SPDX-License-Identifier: MIT -->
# Development

## Tests

```sh
make test
make ci
make hooks
```

`make test` runs Swift Testing through `scripts/test.sh`, which supports full
Xcode and Command Line Tools layouts. `make ci` builds debug and release, runs
the tests, and lints source headers, whitespace, shell syntax, and the
repository's no-em-dash rule. Retained Monitor source and regression tests still
compile; retired-product packaging is outside the default gate.

The pre-push hook and GitHub Actions call the same CI script. Add `--smoke` for
the desktop fake-runner test or `--real` for the Ollama lifecycle gate.

```sh
./scripts/smoke-test.sh       # fake runner; logged-in desktop required
./scripts/validate-real.sh    # real Ollama
make demo                     # isolated narrated wedge recovery
```

The manual `real-ollama.yml` workflow runs the live Ollama gate on GitHub. Test
evidence lives in [VALIDATION-REPORT.md](../VALIDATION-REPORT.md). The
[product plan](product-plan.md) defines the next local validation milestones.

## Full Hearth release

`scripts/release.sh` builds, Developer ID signs, notarizes, staples, and packages
the app as DMG and ZIP. Supply a signing identity plus either a Keychain profile:

```sh
export HEARTH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export HEARTH_NOTARY_PROFILE="HearthNotary"
./scripts/release.sh
```

or an App Store Connect API key:

```sh
export HEARTH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export HEARTH_NOTARY_KEY="$HOME/path/AuthKey_XXXX.p8"
export HEARTH_NOTARY_KEY_ID="XXXX"
export HEARTH_NOTARY_ISSUER="<issuer-uuid>"
./scripts/release.sh
```

Attach the DMG, ZIP, `SHA256SUMS`, and `RELEASE-PROVENANCE.txt` to the GitHub
release. The `adamskijow/homebrew-tap` sync workflow updates its cask from the
latest release.

Pushing a `v*` tag triggers `release.yml`. It verifies that the tag matches the
bundle version, points at the checked-out commit, and belongs to `origin/main`.
Configured signing secrets enable hosted publication; otherwise the workflow
runs only the release gate and artifacts must be published locally.

## Retired Monitor source

Standalone Hearth Monitor was retired on September 7, 2026. Its source, tests,
and historical artifacts remain available. New features and App Store work are
outside the active roadmap. See [retirement and migration](hearth-monitor.md).

To inspect the archived universal sandbox app locally:

```sh
./scripts/ci.sh --legacy-monitor
```

This adds ad-hoc Monitor packaging and the sandbox boundary audit to the normal
gate. It does not publish a release or contact App Store Connect.
`--all` selects the supported product's smoke and real-runner checks; it does
not implicitly select this legacy packaging step.

Monitor Developer ID release, App Store packaging, and upload scripts exit with
a retirement notice. Original release procedures are preserved in the
[0.2.0 tagged source](https://github.com/adamskijow/Hearth/tree/hearth-monitor-v0.2.0).

Historical sampling scripts remain for reference. To remove an existing local
sampling agent, use:

```sh
./scripts/install-dogfood-monitor-agent.sh --uninstall
```
